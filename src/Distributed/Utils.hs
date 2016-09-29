module Distributed.Utils
    ( withRegistry
    ) where

import Control.Distributed.Process

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
