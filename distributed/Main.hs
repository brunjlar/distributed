{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}

module Main where

import           Control.Concurrent                                 (threadDelay)
import qualified Control.Distributed.Process.Backend.SimpleLocalnet as S
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad
import           Data.Time.Clock
import           Distributed
import           Options
import           System.Random
import           Text.Printf                                        (printf)

-- Agent code, supposed to run on all "slave" nodes.
-- It takes a list of all (slave) nodes, the time to send and the random seed as arguments.

agent :: ([NodeId], Int, Int) -> Process ()
agent (nodes, sf, sd) = withBroadcast nodes (Just 1000) $ \s r -> do

    say $ printf "agent started with seed %d" sd
    now <- liftIO getCurrentTime
    let sendUntil = addUTCTime (fromIntegral sf) now
        l         = length nodes

    -- spawn a thread to permanently broadcast random messages until the sending time is up
    _ <- spawnLocal $ send' s sendUntil

    -- keep receiving messages and accumulating the result until all random broadcasts have been received
    receive' r l 0 0 0

  where

    send' :: ((Maybe Double) -> Process ()) -> UTCTime -> Process ()
    send' s sendUntil = go (mkStdGen sd)

      where

        go :: StdGen -> Process ()
        go g = do
            now <- liftIO getCurrentTime
            if now >= sendUntil
               then s Nothing >> say "stopped sending" -- sending time is up, indicate termination
               else do
                  let (x, g') = randomR (0, 1) g
                  s $ Just x
                  go g'

    receive' ::    ReceivePort (NodeId, Maybe Double)
                -> Int
                -> Int
                -> Int
                -> Double
                -> Process ()
    receive' r !l !nothings !justs !sm
        | nothings == l = let msg = show (justs, sm) in say msg >> liftIO (putStrLn msg) -- report result
        | otherwise     = do
            mx <- receiveChan r
            case mx of
                (_, Nothing) -> receive' r l (succ nothings) justs sm
                (_, Just x)  -> do
                    let justs' = succ justs
                        sm'    = sm + fromIntegral justs' * x -- accumulate result
                    receive' r l nothings justs' sm'

remotable ['agent]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

-- "Master" code, which spawns the "agent" code to all slave nodes and terminates all agents
-- when the time is up.

master :: S.Backend -> Int -> Int -> Int -> [NodeId] -> Process ()
master backend sf wf s nodes = do
    say "master started"
    forM_ (zip nodes [s..]) $
        \(node, s') -> spawn node ($(mkClosure 'agent) (nodes, sf, s'))
    say $ "agents started"
    say $ printf "sending for %d second(s)" sf
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
