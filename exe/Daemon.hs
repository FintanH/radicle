{-# OPTIONS_GHC -fno-warn-orphans #-}

module Daemon where

import           Protolude hiding (fromStrict, option)

import           Control.Monad.Except
import qualified Data.Aeson as A
import           Data.ByteString.Lazy (fromStrict)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Network.HTTP.Types.URI as URL
import           Network.Wai.Handler.Warp (run)
import           Servant

import qualified Radicle.Internal.UUID as UUID
import           Server.Common

import           Radicle
import           Radicle.Daemon.Ipfs

-- * Types

instance A.ToJSON MachineId

-- TODO(james): remove the protocol prefix
instance FromHttpApiData MachineId where
  parseUrlPiece = Right . MachineId . toS . URL.urlDecode False . toS
  parseQueryParam = parseUrlPiece

newtype JsonValue = JsonValue { jsonValue :: Value }

instance A.FromJSON JsonValue where
  parseJSON = A.withText "JsonValue" $ \t -> do
      v <- case parse "[daemon]" t of
        Left err -> fail $ "failed to parse Radicle expression: " <> show err
        Right v  -> pure v
      pure (JsonValue v)

instance A.ToJSON JsonValue where
  toJSON (JsonValue v) = A.String $ renderCompactPretty v

newtype Expression = Expression { expression :: JsonValue }
  deriving (Generic)

instance A.ToJSON Expression
instance A.FromJSON Expression

newtype Expressions = Expressions { expressions :: [JsonValue] }
  deriving (Generic)

instance A.FromJSON Expressions
instance A.ToJSON Expressions

newtype SendResult = SendResult
  { results :: [JsonValue]
  } deriving (A.ToJSON)

-- * API

type Query = "query" :> ReqBody '[JSON] Expression  :> Post '[JSON] Expression
type Send  = "send"  :> ReqBody '[JSON] Expressions :> Post '[JSON] SendResult
type New   = "new"   :> Post '[JSON] MachineId

type DaemonApi =
  "v0" :> "machines" :> ( Capture "machineId" MachineId :> ( Query :<|> Send ) :<|> New )

daemonApi :: Proxy DaemonApi
daemonApi = Proxy

-- * Main

main :: IO ()
main = do
    let port = 8909 -- TODO(james): decide how/where/if port can be confugured
    -- TODO(james): - initAsReader all the reader chains
    --              - initAsWriter all the writer chains
    chains <- Chains <$> newMVar Map.empty
    let app = serve daemonApi (server chains)
    logInfo "Start listening" [("port", show port)]
    run port app

type IpfsChain = Chain MachineId MachineEntryIndex TopicSubscription
type IpfsChains = Chains MachineId MachineEntryIndex TopicSubscription

server :: IpfsChains -> Server DaemonApi
server chains = machineEndpoints :<|> newMachine chains
  where
    machineEndpoints id = query chains id :<|> send chains id

-- * Endpoints

-- | Create a new IPFS machine and initialise the daemon as as the
-- /writer/.
newMachine :: IpfsChains -> Handler MachineId
newMachine chains = do
  id_ <- createMachine
  case id_ of
    Left err -> throwError $ err500 { errBody = fromStrict $ encodeUtf8 err }
    Right id -> liftIO $ do
      sub <- liftIO $ initSubscription id
      let m = (emptyMachine id Writer sub)
      insertMachine chains m
      actAsWriter chains m
      -- TODO: check that we have persisted in config file that this
      -- daemon follows this machine.
      pure id

-- | Evaluate an expression.
query :: IpfsChains -> MachineId -> Expression -> Handler Expression
query chains id (Expression (JsonValue v)) = do
  m <- loadPinSubscribe chains id
  case fst <$> runIdentity $ runLang (chainState m) $ eval v of
    Left err -> throwError $ err400 { errBody = fromStrict $ encodeUtf8 (renderPrettyDef err) }
    Right rv -> pure (Expression (JsonValue rv))

-- | Write a new expression to an IPFS machine.
send :: IpfsChains -> MachineId -> Expressions -> Handler SendResult
send chains id (Expressions jvs) = do
  m <- loadPinSubscribe chains id
  case chainMode m of
    Writer -> do
      let vs = jsonValue <$> jvs
      (_, rs) <- withErr err500 $ writeInputs chains m vs Nothing
      pure SendResult{ results = JsonValue <$> rs }
    Reader -> do
      nonce <- liftIO $ UUID.uuid
      let isResponse = \case
            New NewInputs{ nonce = Just nonce' } | nonce == nonce' -> True
            _ -> False
      -- TODO(james): decide what a good timeout is.
      msg_ <- liftIO $ subscribeOne (chainSubscription m) 10000 isResponse
      case msg_ of
        Nothing -> throwError $ err500 { errBody = fromStrict $ encodeUtf8 "The writer for this IPFS machine appears to be offline." }
        Just (New NewInputs{results = rs}) -> pure SendResult{ results = JsonValue <$> rs }
        _ -> throwError $ err500 { errBody = fromStrict $ encodeUtf8 "Error: didn't filter machine topic messages correctly." }

-- * Helpers

lookupMachine :: (MonadIO m) => IpfsChains -> MachineId -> m (Maybe IpfsChain)
lookupMachine chains id = do
  cs <- liftIO $ readMVar (getChains chains)
  pure (Map.lookup id cs)

-- | Given an 'MachineId', makes sure the machine state is materialised,
-- makes sure the inputs are pinned and subscribes to the topic for
-- updates. Returns the chain.
loadPinSubscribe :: IpfsChains -> MachineId -> Handler IpfsChain
loadPinSubscribe chains id = do
  m_ <- lookupMachine chains id
  case m_ of
    Nothing ->
      -- In this case we have not seen the machine before, se we must
      -- be a reader.
      withErr err500 $ initAsReader chains id
    Just m -> case chainMode m of
      Writer -> pure m
      Reader -> do
        m' <- withErr err500 $ catchUpMachine chains m
        liftIO $ bumpPolling m'
        pure m'

-- Initialise the daemon service for this machine in /reader mode/.
initAsReader :: IpfsChains -> MachineId -> ExceptT Text IO IpfsChain
initAsReader chains id = do
    m <- loadMachine Reader chains id
    _ <- liftIO $ addHandler (chainSubscription m) onMsg
    liftIO $ bumpPolling m
    -- TODO: check that we have persisted in config file that this
    -- daemon follows this machine.
    pure m
  where
    onMsg = \case
      New NewInputs{..} -> do
        m_ <- lookupMachine chains id
        case m_ of
          Nothing -> panic "Subscribed for changes on a non-loaded machine!"
          Just m -> runExceptT (refreshAsReader chains m) >> pure () -- TODO(james): log error somewhere
      _ -> pure ()

initAsWriter :: IpfsChains -> MachineId -> ExceptT Text IO IpfsChain
initAsWriter chains id = do
  m <- loadMachine Writer chains id
  liftIO $ actAsWriter chains m
  pure m

-- Loads a machine from IPFS.
loadMachine :: ReaderOrWriter -> IpfsChains -> MachineId -> ExceptT Text IO IpfsChain
loadMachine mode chains id = do
  (idx, is) <- liftIO $ machineInputsFrom id Nothing
  sub <- liftIO $ initSubscription id
  let m = emptyMachine id mode sub
  fst <$> addInputs chains m is (pure idx) (const (pure ()))

-- Given a cached machine, loads updates from IPFS.
catchUpMachine :: IpfsChains -> IpfsChain -> ExceptT Text IO IpfsChain
catchUpMachine chains m = do
  (idx, is) <- liftIO $ machineInputsFrom (chainName m) (chainLastIndex m)
  fst <$> addInputs chains m is (pure idx) (const (pure ()))

-- Add inputs to a cached machine.
addInputs
  :: IpfsChains
  -> IpfsChain
  -> [Value]
  -> IO MachineEntryIndex -- ^ Determine the new index.
  -> ([Value] -> IO ())   -- ^ Performed after the chain is cached.
  -> ExceptT Text IO (IpfsChain, [Value])
addInputs chains m is getIdx after = case advanceChain m is of
    Left err -> ExceptT $ pure $ Left (renderCompactPretty err)
    Right (rs, newState) -> do
      idx <- liftIO getIdx
      let news = Seq.fromList $ zip is rs
          m' = m { chainState = newState
                 , chainLastIndex = Just idx
                 , chainEvalPairs = chainEvalPairs m Seq.>< news
                 }
      liftIO $ insertMachine chains m'
      liftIO (after rs)
      pure (m', rs)

-- Write some inputs to a machine as the writer, sends out a
-- 'NewInput' message.
writeInputs :: IpfsChains -> IpfsChain -> [Value] -> Maybe Text -> ExceptT Text IO (IpfsChain, [Value])
writeInputs chains chain is nonce =
  let id = chainName chain
  in addInputs chains chain is (writeIpfs id is) (\rs -> publish id (New NewInputs{results = rs, ..}))

-- Subscribes the daemon to the machine's pubsub topic to listen for
-- input requests.
actAsWriter :: IpfsChains -> IpfsChain -> IO ()
actAsWriter chains m = addHandler (chainSubscription m) onMsg *> pure ()
  where
    id = chainName m
    onMsg = \case
      Req ReqInputs{..} -> do
        m_ <- lookupMachine chains id
        case m_ of
          Nothing -> panic "Daemon was setup as writer for a chain it hasn't laoded!"
          Just m' -> runExceptT (writeInputs chains m' expressions (Just nonce)) >> pure () -- TODO(james): log error somewhere
      _ -> pure ()

refreshAsReader :: IpfsChains -> IpfsChain -> ExceptT Text IO IpfsChain
refreshAsReader chains m = do
  m' <- catchUpMachine chains m
  liftIO $ bumpPolling m'
  pure m'

-- Do some high-freq polling for a while.
bumpPolling :: IpfsChain -> IO ()
bumpPolling _ = pure () -- TODO: polling

-- TODO(james): rename to cacheMachine maybe
insertMachine :: IpfsChains -> IpfsChain -> IO ()
insertMachine chains chain = modifyMVar (getChains chains) $ \cs -> pure (Map.insert (chainName chain) chain cs, ())

emptyMachine :: MachineId -> ReaderOrWriter -> TopicSubscription -> IpfsChain
emptyMachine id mode sub =
  Chain{ chainName = id
       , chainState = pureEnv
       , chainEvalPairs = mempty
       , chainLastIndex = Nothing
       , chainMode = mode
       , chainSubscription = sub
       }

-- TODO(james): There is no pinning anywhere.

withErr :: ServantErr -> ExceptT Text IO a -> Handler a
withErr code x_ = do
  x <- liftIO $ runExceptT x_
  case x of
    Left err -> throwError $ code { errBody = fromStrict $ encodeUtf8 err }
    Right y  -> pure y
