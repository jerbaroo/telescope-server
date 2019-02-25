{-# OPTIONS_GHC -fno-warn-missing-fields #-}

{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators    #-}

-- | A server for a data store.
module Telescope.Server where

import           Control.Concurrent            (forkIO)
import           Control.Monad                 (forever, void)
import           Control.Monad.IO.Class        (liftIO)
import           Data.ByteString.Char8         (ByteString, pack, unpack)
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import qualified Network.Wai.Handler.Warp      as Warp
import           Network.WebSockets            (receiveData, sendBinaryData)
import           Network.WebSockets.Connection (Connection)
import           Servant                       ((:<|>) (..), (:>), Capture,
                                                DeleteNoContent, Get, Handler,
                                                HasServer, JSON, NoContent (..),
                                                PostNoContent, Proxy (..),
                                                ReqBody, Server, serve)
import           Servant.API.WebSocket         (WebSocket)

import           Telescope.Monad               (runScope)
import           Telescope.Operations          (onChangeS, rmAllS, setAllS,
                                                viewAllS)
import           Telescope.Source              (SourceConfig)
import           Telescope.Storable            (RowKey (..), TableKey (..))

-- | A server implementing the 'SourceAPI' for a data source.
sourceServer :: SourceConfig -> Server SourceAPI
sourceServer config =

       (rmAllHandler
  :<|> viewAllHandler
  :<|> setAllHandler)
  :<|> updateHandler

  where rmAllHandler :: String -> Handler NoContent
        rmAllHandler tkS = liftIO $ do
          runScope config $ rmAllS $ TableKey tkS
          pure NoContent

        viewAllHandler :: String -> Handler [(String, String)]
        viewAllHandler tkS = liftIO $ do
          eitherMaybeValue <- runScope config $ viewAllS $ TableKey tkS
          print eitherMaybeValue
          case eitherMaybeValue of
            Left s -> liftIO $ print s >> pure []
            Right maybeValue -> pure $
              map (\(RowKey k, v) -> (k, unpack v)) $ Map.toList maybeValue

        setAllHandler ::
          String -> Map String String -> Handler NoContent
        setAllHandler tkS all = liftIO $ do
          runScope config $ setAllS (TableKey tkS) $
            Map.fromList $ [(RowKey k, pack v) | (k, v) <- Map.toList all]
          pure NoContent

        updateHandler :: Connection -> Handler ()
        updateHandler c = do
          liftIO $ putStrLn $ "Connected!"
          liftIO . void . forkIO . forever $ do
            print "Waiting to receive subscription data"
            message <- receiveData c :: IO ByteString
            print "Received subscription data"
            let sub :: Sub
                sub@(Sub tk k) = read $ unpack message
            print $ "Read subscription: " ++ show sub
            runScope config $ onChangeS
              (tk, k, \v ->
                  print ("tk: " ++ show tk ++
                         " k:" ++ show k ++
                         " v:" ++ unpack v)
                  >> sendBinaryData c message)

data Sub = Sub TableKey RowKey
  deriving (Read, Show)

-- | Run a Server on a port using warp.
runWarp :: HasServer a '[] => Int -> Server a -> Proxy a -> IO ()
runWarp port server proxy = Warp.run port $ serve proxy server

-- | Run a server for the given data store.
-- TODO: Merge runWarp and rename to runScopeServer.
runStoreServer :: SourceConfig -> Int -> IO ()
runStoreServer config port =
  runWarp port (sourceServer config) (Proxy :: Proxy SourceAPI)