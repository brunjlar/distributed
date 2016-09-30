{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}

module Main where

import           Control.Concurrent                                 (threadDelay)
import           Control.Concurrent.MVar
import qualified Control.Distributed.Process.Backend.SimpleLocalnet as S
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad
import           Data.Time.Clock
import           Distributed
import           Options
import           System.Random
import           Text.Printf                                        (printf)

agent :: ([NodeId], Int, Int) -> Process ()
agent (nodes, sf, sd) = withBroadcast nodes $ \s r -> do
    say $ printf "agent started with seed %d" sd
    now <- liftIO getCurrentTime
    let sendUntil = addUTCTime (fromIntegral sf) now
        l         = length nodes
    cnt <- liftIO $ newMVar 0
    _ <- spawnLocal $ send' s l cnt sendUntil
    receive' r l cnt 0 0 0

  where

    send' :: SendPort (Maybe Double) -> Int -> MVar Int -> UTCTime -> Process ()
    send' s l cnt sendUntil = go (mkStdGen sd)

      where

        go :: StdGen -> Process ()
        go g = do
            now <- liftIO getCurrentTime
            if now >= sendUntil
               then sendChan s Nothing
               else do
                   c <- liftIO $ takeMVar cnt
                   if c <= 0
                      then do
                          let (x, g') = randomR (0, 1) g
                          sendChan s $ Just x
                          liftIO $ putMVar cnt l
                          go g'
                      else liftIO (putMVar cnt c) >> go g

    receive' ::    ReceivePort (NodeId, Maybe Double)
                -> Int
                -> MVar Int
                -> Int
                -> Int
                -> Double
                -> Process ()
    receive' r !l !cnt !nothings !justs !sm
        | nothings == l = say $ show (justs, sm)
        | otherwise     = do
            mx <- receiveChan r
            case mx of
                (_, Nothing) -> receive' r l cnt (succ nothings) justs sm
                (_, Just x)  -> do
                    liftIO $ modifyMVar cnt (\c -> return (pred c, ()))
                    let justs' = succ justs
                        sm'    = sm + fromIntegral justs' * x
                    receive' r l cnt nothings justs' sm'

remotable ['agent]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

master :: S.Backend -> Int -> Int -> Int -> [NodeId] -> Process ()
master backend sf wf s nodes = do
    say "master started"
    forM_ (zip nodes [s..]) $
        \(node, s') -> spawn node ($(mkClosure 'agent) (nodes, sf, s'))
    say $ printf "agents started, sending for %d second(s)" sf
    liftIO $ threadDelay $ 1000000 * sf
    say $ printf "waiting for %d second(s)" wf
    liftIO $ threadDelay $ 1000000 * wf
    S.terminateAllSlaves backend

data MainOptions = MainOptions
    { host :: String
    , port :: String
    }

instance Options MainOptions where

    defineOptions = MainOptions
        <$> simpleOption "host" "localhost" "the node host"
        <*> simpleOption "port" "8080" "the node port"

data MasterOptions = MasterOptions
    { sendFor :: Int
    , waitFor :: Int
    , seed    :: Int
    }

instance Options MasterOptions where

    defineOptions = MasterOptions
        <$> simpleOption "send-for" 1 "time to send messages (in seconds)"
        <*> simpleOption "wait-for" 1 "time to wait for the results (in seconds)"
        <*> simpleOption "with-seed" 123456 "the random number generator seed"

data SlaveOptions = SlaveOptions

instance Options SlaveOptions where

    defineOptions = pure SlaveOptions

main :: IO ()
main = runSubcommand
    [ subcommand "master" m
    , subcommand "slave" s
    ]

  where

    m :: MainOptions -> MasterOptions -> [String] -> IO ()
    m opt opt' _ = do
        backend <- S.initializeBackend (host opt) (port opt) myRemoteTable
        let sf = max 1 $ sendFor opt'
            wf = max 1 $ waitFor opt'
        S.startMaster backend (master backend sf wf $ seed opt')

    s :: MainOptions -> SlaveOptions -> [String] -> IO ()
    s opt SlaveOptions _ = do
        backend <- S.initializeBackend (host opt) (port opt) myRemoteTable
        S.startSlave backend
