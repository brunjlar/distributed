{-# LANGUAGE TemplateHaskell #-}

module Main where

import           Control.Concurrent                                 (threadDelay)
import qualified Control.Distributed.Process.Backend.SimpleLocalnet as S
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad
import qualified Data.Map.Strict                                    as M
import           Distributed
import           System.Environment

agent :: [NodeId] -> Process ()
agent nodes = withChannels nodes $ \m -> do
    myNode <- getSelfNode
    forM_ (M.toAscList m) $ \(node, channel) -> do
        let message = show myNode ++ " -> " ++ show node
        say $ "sending '" ++ message ++ "'"
        sendChan (sendPort channel) message
        message' <- receiveChan (receivePort channel)
        say $ "received '" ++ message' ++ "'"

remotable ['agent]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

master :: S.Backend -> [NodeId] -> Process ()
master backend nodes = do
    say $ "master started, slaves: " ++ show nodes
    forM_ nodes $ \node -> spawn node ($(mkClosure 'agent) nodes)
    liftIO $ threadDelay 1000000
    S.terminateAllSlaves backend

main :: IO ()
main = do
    args <- getArgs
    case args of
      ["slave", host, port] -> do
          backend <- S.initializeBackend host port myRemoteTable
          S.startSlave backend
      ["master", host, port] -> do
          backend <- S.initializeBackend host port myRemoteTable
          S.startMaster backend (master backend)
      _                      -> putStrLn "unknown parameters"
