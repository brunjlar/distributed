-- My interpretation/implementation of the "broadcast with total message ordering abstraction",
-- taken from the book "Distributed Algorithms for Message Passing Systems" by Michel Raynal.
-- The idea is to provide - in a modular way - the capability to layer "broadcast" on top of a
-- (totally connected) network of Cloud Haskell nodes.

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

module Distributed.Broadcast
    ( withBroadcast
    ) where

import           Control.Concurrent.MVar     (MVar, newMVar, takeMVar, putMVar)
import           Control.Concurrent.QSem     (QSem, newQSem, waitQSem, signalQSem)
import           Control.Distributed.Process
import           Control.Monad
import           Data.Binary                 (Binary)
import           Data.Heap                   (MinPrioHeap)
import qualified Data.Heap                   as H
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as M
import           Data.Typeable               (Typeable)
import           Distributed.Channel
import           GHC.Generics                (Generic)

data Timestamp = Timestamp
    { tsClock :: !Integer
    , tsNode  :: !NodeId
    } deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary Timestamp

type Clocks = Map NodeId Integer

type Pending a = MinPrioHeap Timestamp a

type State a = (Clocks, Pending a)

data Msg a =
      CatchUp Timestamp
    | Broadcast !Timestamp !a deriving (Typeable, Generic)

instance Binary a => Binary (Msg a)

-- withBroadcast provides the broadcast abstraction.
-- It takes the list of all nodes and
-- an optional throttle to cap the number of broadcasted messages waiting for delivery
-- and then transforms a process with broadcast capability
-- (represented by a function to send messages of type a and a channel to receive broadcasts
-- of type (NodeId, a))
-- into a "normal" process.

withBroadcast ::    forall a b. (Typeable a, Binary a)
                 => [NodeId]
                 -> Maybe Int
                 -> ((a -> Process ()) -> ReceivePort (NodeId, a) -> Process b)
                 -> Process b
withBroadcast nodes throttle f = withChannels nodes $ \m -> do

    -- set up the broadcasting infrastructure
    let clocks  = M.fromList [(node, 0 :: Integer) | node <- nodes]
        pending = H.empty
    state       <- liftIO $ newMVar (clocks, pending)
    msem        <- maybe
                    (return Nothing)
                    (\t -> liftIO (newQSem $ max t 1) >>= return . Just)
                    throttle
    (sb, rb)    <- newChan
    (sd, rd)    <- newChan
    receivers   <- forM (M.toAscList m) $ \(n, _) -> spawnLocal $ receive state m n
    broadcaster <- spawnLocal $ broadcast state m rb
    deliverer   <- spawnLocal $ deliver state msem sd

    -- run the "enhanced" process, using the broadcasting infrastructure
    x <- f (broadcast' msem sb) rd

    -- clean up
    kill deliverer "killing deliverer"
    kill broadcaster "killing broadcaster"
    forM_ receivers $ \receiver -> kill receiver "killing receiver"

    -- return the result
    return x

  where

    broadcast :: MVar (State a) -> (Map NodeId (Channel (Msg a))) -> ReceivePort a -> Process ()
    broadcast state m r = forever $ do
        x <- receiveChan r
        (clocks, pending) <- liftIO $ takeMVar state
        myNode <- getSelfNode
        let c        = clocks M.! myNode
            !c'      = succ c
            ts       = Timestamp c' myNode
            clocks'  = M.insert myNode c' clocks
            pending' = H.insert (ts, x) pending
            msg      = Broadcast ts x
        forM_ (M.toAscList m) $ \(_, ch) -> sendChan (sendPort ch) msg
        liftIO $ putMVar state (clocks', pending')

    deliver :: MVar (State a) -> Maybe QSem -> SendPort (NodeId, a) -> Process ()
    deliver state msem s = forever $ do
        (clocks, pending) <- liftIO $ takeMVar state
        case H.viewHead pending of
            Nothing      -> liftIO (putMVar state (clocks, pending))
            Just (ts, x) -> do
                let node = tsNode ts
                    tss  = map (\(n, i) -> Timestamp i n) $ filter ((/= node) . fst) $ M.toAscList clocks
                if all (ts <) tss
                   then do
                       sendChan s (node, x)
                       let Just pending' = H.viewTail pending
                       liftIO $ putMVar state (clocks, pending')
                       case msem of
                           Nothing  -> return ()
                           Just sem -> do
                               myNode <- getSelfNode
                               when (myNode == node) $ liftIO $ signalQSem sem
                   else liftIO (putMVar state (clocks, pending))

    receive :: MVar (State a) -> Map NodeId (Channel (Msg a)) -> NodeId -> Process ()
    receive state m node =
        let r = receivePort $ m M.! node
        in  forever $ do
        msg <- receiveChan r
        case msg of
            CatchUp ts     -> liftIO $ do
                (clocks, pending) <- takeMVar state
                let clocks' = M.insert (tsNode ts) (tsClock ts) clocks
                putMVar state (clocks', pending)
            Broadcast ts x -> do
                (clocks, pending) <- liftIO $ takeMVar state
                let clocks'  = M.insert (tsNode ts) (tsClock ts) clocks
                    pending' = H.insert (ts, x) pending
                myNode <- getSelfNode
                if tsClock ts >= clocks' M.! myNode
                   then do
                       let c        = succ $ tsClock ts
                           clocks'' = M.insert myNode c clocks'
                           msg'     = CatchUp $ Timestamp c myNode
                       forM_ (M.toAscList m) $ \(_, ch) -> sendChan (sendPort ch) msg'
                       liftIO $ putMVar state (clocks'', pending')
                   else liftIO $ putMVar state (clocks', pending')

    broadcast' :: Maybe QSem -> SendPort a -> a -> Process ()
    broadcast' Nothing    s x = sendChan s x
    broadcast' (Just sem) s x = liftIO (waitQSem sem) >> sendChan s x
