module Distributed.Utils
    ( withRegistry
    ) where

import Control.Distributed.Process

-- simple utility "layer", so that a process can assume that a port with a given name has been registered

withRegistry :: String -> Process a -> Process a
withRegistry s p = do
    myPid <- getSelfPid
    mPid  <- whereis s
    case mPid of
        Nothing -> do
            register s myPid
            x <- p
            unregister s
            return x
        Just pid -> do
            reregister s myPid
            x <- p
            reregister s pid
            return x
