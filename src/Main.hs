{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}

module Main where

import           Control.Concurrent                                 (threadDelay)
import           Control.Distributed.Process
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad
import           Data.Binary                                        (Binary)
import           Data.List                                          (foldl')
import           Data.Map.Strict                                    (Map)
import qualified Data.Map.Strict                                    as M
import           Data.Typeable                                      (Typeable)
import           GHC.Generics                                       (Generic)
import           System.Environment
import           System.Random                                      (StdGen, mkStdGen, random)

type Clock = Integer

data TimeStamp = TimeStamp
    { tsClock :: Clock
    , tsNode  :: NodeId
    }
    deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary TimeStamp

data RandomMessage = RandomMessage
    { rmTimeStamp :: TimeStamp
    , rmPayLoad   :: Double
    }
    deriving (Show, Typeable, Generic)

instance Binary RandomMessage

delay :: Int -> Process ()
delay = liftIO . threadDelay . (1000000 *)

agent :: ([NodeId], Int, Int, Int) -> Process ()
agent (nodes, seed, phase1, phase2) = do
    say "agent started"
    (sResult, rResult) <- newChan
    (sRM, rRM)         <- newChan
    (sDouble, rDouble) <- newChan
    (sUnit, rUnit)     <- newChan
    (sUnit', rUnit')   <- newChan
    _                  <- spawnLocal $ senderAgent sResult rUnit' rRM rDouble nodes
    creator            <- spawnLocal $ creatorAgent seed rUnit sDouble
    receiver           <- spawnLocal $ receiverAgent sRM sUnit
    delay phase1
    say "end phase 1"
    kill creator "end of phase 1"
    delay phase2
    say "end phase 2"
    kill receiver "end of phase 2"
    sendChan sUnit' ()
    r <- receiveChan rResult
    say $ show r

creatorAgent :: Int -> ReceivePort () -> SendPort Double -> Process ()
creatorAgent seed rUnit sDouble = f (mkStdGen seed) where

    f :: StdGen -> Process ()
    f g = do
        () <- receiveChan rUnit
        let (r, g') = random g
        sendChan sDouble r
        f g'

data SenderMessage =
    Report
    | Received RandomMessage
    | Send Double
    deriving (Show, Typeable, Generic)

instance Binary SenderMessage

data State = State
    { stMaxNode :: NodeId
    , stClock   :: Clock
    , stClocks  :: Map NodeId Clock
    , stCut     :: Clock
    , stMap     :: Map TimeStamp Double
    , stCount   :: Integer
    , stSum     :: Double
    } deriving Show

initialState :: [NodeId] -> State
initialState nodes = State
    { stMaxNode = maximum nodes
    , stClock   = 0
    , stClocks  = M.fromList [(node, -1) | node <- nodes]
    , stCut     = -1
    , stMap     = M.empty
    , stCount   = 0
    , stSum     = 0
    }

splitLeGt :: Ord k => k -> Map k a -> (Map k a, Map k a)
splitLeGt key m = case M.splitLookup key m of
    (le, Nothing, gt) -> (le, gt)
    (le, Just x, gt)  -> (M.insert key x le, gt)

updateState :: RandomMessage -> State -> State
updateState rm st =
    let t                   = rmTimeStamp rm
        a                   = tsClock t
        x                   = rmPayLoad rm
        c'                  = succ $ max (succ a) (stClock st)
        m'                  = M.insert t x $ stMap st
        cs'                 = M.insert (tsNode t) a $ stClocks st
        cut'                = minimum $ snd <$> M.toList cs'
        (count', sum', m'') = if cut' == stCut st
                            then (stCut st, stSum st, m')
                            else let t'       = TimeStamp { tsClock = cut', tsNode = stMaxNode st }
                                     (le, gt) = splitLeGt t' $ stMap st
                                     (c, s)   = foldl' fold (stCount st, stSum st) le
                                 in  (c, s, gt)
    in  st { stClock  = c'
           , stClocks = cs'
           , stCut    = cut'
           , stMap    = m''
           , stCount  = count'
           , stSum    = sum'
           }

getResult :: State -> (Integer, Double)
getResult st = foldl' fold (stCount st, stSum st) $ stMap st

fold :: (Integer, Double) -> Double -> (Integer, Double)
fold (c, s) x =
    let !c' = succ c
        !s' = s + fromIntegral c' * x
    in  (c', s')

senderAgent ::    SendPort (Integer, Double)
               -> ReceivePort ()
               -> ReceivePort RandomMessage
               -> ReceivePort Double
               -> [NodeId]
               -> Process ()
senderAgent sResult rUnit rRM rDouble nodes = do
    myNodeId  <- getSelfNode
    receivers <- forM nodes getReceiver
    r         <- mergePortsBiased [ const Report <$> rUnit
                                  , Received <$> rRM
                                  , Send <$> rDouble
                                  ]
    go myNodeId receivers r $ initialState nodes

  where

    getReceiver :: NodeId -> Process ProcessId
    getReceiver node = do
        whereisRemoteAsync node "receiver"
        WhereIsReply _ mPid <- expect
        case mPid of
          Nothing  -> getReceiver node
          Just pid -> return pid

    go :: NodeId -> [ProcessId] -> ReceivePort SenderMessage -> State -> Process ()
    go myNodeId receivers rSM st = do
        sm <- receiveChan rSM
        case sm of
          Report      -> let !r = getResult st in sendChan sResult r
          Received rm -> go myNodeId receivers rSM $ updateState rm st
          Send x      -> do
              let t  = TimeStamp { tsClock = stClock st, tsNode = myNodeId }
                  rm = RandomMessage { rmTimeStamp = t, rmPayLoad = x }
              forM_ receivers $ \pid -> send pid rm
              go myNodeId receivers rSM $ st { stClock = succ $ stClock st }

receiverAgent :: SendPort RandomMessage -> SendPort () -> Process ()
receiverAgent sRM sUnit = do
    myPid <- getSelfPid
    register "receiver" myPid
    sendChan sUnit ()
    forever $ do
        m <- expectTimeout 0
        case m of
          Nothing -> sendChan sUnit ()
          Just rm -> sendChan sRM rm

remotable ['agent]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

master :: Backend -> Int -> Int -> Int -> [NodeId] -> Process ()
master backend seed phase1 phase2 nodes = do
    forM_ (zip [1..] nodes) $ \(i, node) ->
        spawn node ($(mkClosure 'agent) (nodes, i + seed, phase1, phase2))
    delay (phase1 + phase2)
    say "time's up!"
    delay 1
    terminateAllSlaves backend

main :: IO ()
main = do
    args <- getArgs
    case args of
      ["master", host, port, seed, phase1, phase2] -> do
          backend <- initializeBackend host port myRemoteTable
          startMaster backend (master backend (read seed) (read phase1) (read phase2))
      ["slave", host, port]  -> do
          backend <- initializeBackend host port myRemoteTable
          startSlave backend
      _                      -> putStrLn "unknown parameters"
