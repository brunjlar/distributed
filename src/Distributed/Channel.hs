{-# LANGUAGE ScopedTypeVariables #-}

module Distributed.Channel
    ( Channel
    , sendPort
    , receivePort
    , withChannels
    ) where

import           Control.Distributed.Process
import           Control.Monad
import           Data.Binary                 (Binary)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as M
import           Data.Typeable               (Typeable)
import           Distributed.Utils           (withRegistry)

newtype Channel a = Channel (SendPort a, ReceivePort a)

sendPort :: Channel a -> SendPort a
sendPort (Channel (s, _)) = s

receivePort :: Channel a -> ReceivePort a
receivePort (Channel (_, r)) = r

-- withChannels layers a "bidirectional typed channel" abstraction on top of a fully connected
-- network of Cloud Haskell nodes.
-- It transforms a process that can use a map from nodes to bidirectional typed channels
-- into a "normal" process.

withChannels ::    forall a b. (Typeable a, Binary a)
                => [NodeId]
                -> (Map NodeId (Channel a) -> Process b)
                -> Process b
withChannels nodes f = withRegistry "port" $ do

    -- set up the bidirectional channels
    myNode <- getSelfNode
    let nodes' = filter (/= myNode) nodes
    cs <- forM nodes' getChannel
    let m = M.fromList $ zip nodes' cs

    -- run the "enhanced" process
    f m

  where

    getChannel :: NodeId -> Process (Channel a)
    getChannel node = do
        pid    <- getReceiver node
        (s, r) <- newChan
        send pid s
        s'     <- expect
        return $ Channel (s', r)

    getReceiver :: NodeId -> Process ProcessId
    getReceiver node = do
        whereisRemoteAsync node "port"
        WhereIsReply _ mPid <- expect
        case mPid of
            Nothing  -> getReceiver node
            Just pid -> return pid
