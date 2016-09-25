{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node                   (initRemoteTable)
import Control.Monad
import Data.Binary                                        (Binary)
import Data.Typeable                                      (Typeable)
import GHC.Generics                                       (Generic)
import System.Environment

data MyMessage = Hello NodeId NodeId deriving (Show, Typeable, Generic)

instance Binary MyMessage

slave :: (ProcessId, [NodeId]) -> Process ()
slave (master, nodes) = do
    myPid  <- getSelfPid
    myNode <- getSelfNode
    register "receiver" myPid
    receivers <- mapM getReceiver nodes
    forM_ receivers $ \(node, pid) -> send pid $ Hello myNode node
    wait $ length nodes
    send master myNode

  where

    getReceiver :: NodeId -> Process (NodeId, ProcessId)
    getReceiver node = do
        whereisRemoteAsync node "receiver"
        WhereIsReply _ mPid <- expect
        case mPid of
          Nothing  -> getReceiver node
          Just pid -> return (node, pid)

    wait :: Int -> Process ()
    wait 0 = return ()
    wait n = do
        m <- expect :: Process MyMessage
        say $ show m
        wait $ pred n

remotable ['slave]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

master :: Backend -> [NodeId] -> Process ()
master backend nodes = do
    let n = length nodes
    say $ "master started with " ++ show n ++ " slave node(s)"
    myPid <- getSelfPid
    forM_ nodes $ \node -> spawn node ($(mkClosure 'slave) (myPid, nodes))
    wait n
    say $ show n ++ " node(s) done"
    terminateAllSlaves backend

  where

    wait :: Int -> Process ()
    wait 0 = return ()
    wait n = do
        node <- expect :: Process NodeId
        say $ "done: " ++ show node
        wait $ pred n

main :: IO ()
main = do
    args <- getArgs
    case args of
      ["master", host, port] -> do
          backend <- initializeBackend host port myRemoteTable
          startMaster backend (master backend)
      ["slave", host, port]  -> do
          backend <- initializeBackend host port myRemoteTable
          startSlave backend
      _                      -> putStrLn "unknown parameters"
