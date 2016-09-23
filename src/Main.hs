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

data GalaxyMessage = LookForGalaxy ProcessId | GalaxyFound String
    deriving (Show, Typeable, Generic)

instance Binary GalaxyMessage

traveller :: () -> Process ()
traveller () = do
    say "here's a traveller!"
    LookForGalaxy pid <- expect
    say $ "received message from " ++ show pid
    send pid $ GalaxyFound "Andromeda"
    say "traveller sent message"

remotable ['traveller]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

master :: Backend -> [NodeId] -> Process ()
master backend nodes = do
    say "here's the master!"
    myPid <- getSelfPid
    forM_ nodes $ \node -> do
        nodePid <- spawn node ($(mkClosure 'traveller) ())
        say $ "slave " ++ show node ++ " spawned"
        send nodePid $ LookForGalaxy myPid
        say $ "master sent message to " ++ show nodePid
        GalaxyFound n <- expect
        say $ "found galaxy '" ++ n ++ "'"
        terminateAllSlaves backend
        say "slaves terminated"

main :: IO ()
main = do
    args <- getArgs
    case args of
      ["master", host, port] -> do
          backend <- initializeBackend host port myRemoteTable
          putStrLn "backend initialized"
          startMaster backend (master backend)
          putStrLn "master started"
      ["slave", host, port]  -> do
          backend <- initializeBackend host port myRemoteTable
          putStrLn "backend initialized"
          startSlave backend
          putStrLn "slave started"
      _                      -> putStrLn "unknown parameters"
