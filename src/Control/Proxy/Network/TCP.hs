{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}

{-# OPTIONS_HADDOCK not-home, prune #-}

-- | Utilities to use TCP connections together with the @pipes@ and @pipes-safe@
-- libraries.

-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE


module Control.Proxy.Network.TCP (
   -- * Socket proxies
   socketP,
   socketC,
   -- * Safe socket usage
   withClient,
   withServer,
   accept,
   acceptFork,
   -- * Low level API
   listen,
   connect,
   -- * Settings
   HostPreference(..),
   ) where

import           Control.Concurrent                        (forkIO, ThreadId)
import qualified Control.Exception                         as E
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import qualified Control.Proxy                             as P
import           Control.Proxy.Network
import qualified Control.Proxy.Safe                        as P
import qualified Data.ByteString                           as B
import           Data.List                                 (partition)
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)


-- | Safely run a TCP client.
--
-- The connection socket is safely closed when done.
withClient
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.HostName                   -- ^Server hostname.
  -> Int                           -- ^Server port number.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the
                                   --  communication socket and the server
                                   --  address.
  -> P.ExceptionP p a' a b' b m r
withClient morph host port =
    P.bracket morph connect' close
  where
    connect' = connect host port
    close (s,_) = NS.sClose s


-- | Safely run a TCP server.
--
-- The listening socket is safely closed when done.
withServer
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind to.
  -> Int                           -- ^Port number to bind to.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the listening
                                   --  socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
withServer morph hp port =
    P.bracket morph bind close
  where
    bind = listen hp port
    close (s,_) = NS.sClose s


--------------------------------------------------------------------------------

-- | Socket Producer. Stream data from the socket.
socketP :: (P.Proxy p, MonadIO m)
        => Int -> NS.Socket -> () -> P.Producer p B.ByteString m ()
socketP bufsize sock () = P.runIdentityP loop where
    loop = do bs <- lift . liftIO $ recv sock bufsize
              unless (B.null bs) $ P.respond bs >> loop

-- | Socket Consumer. Stream data to the socket.
socketC :: (P.Proxy p, MonadIO m)
        => NS.Socket -> () -> P.Consumer p B.ByteString m ()
socketC sock = P.runIdentityK . P.foreverK $ loop where
    loop = P.request >=> lift . liftIO . sendAll sock


--------------------------------------------------------------------------------

-- | Accept a connection and run an action on the resulting connection socket
-- and remote address pair, safely closing the connection socket when done. The
-- given socket must be bound to an address and listening for connections.
accept :: NS.Socket -> ((NS.Socket, NS.SockAddr) -> IO b) -> IO b
accept lsock f = do
    client@(csock,_) <- NS.accept lsock
    E.finally (f client) (NS.sClose csock)


-- | Accept a connection and, on a different thread, run an action on the
-- resulting connection socket and remote address pair, safely closing the
-- connection socket when done. The given socket must be bound to an address and
-- listening for connections.
acceptFork :: NS.Socket -> ((NS.Socket, NS.SockAddr) -> IO ()) -> IO ThreadId
acceptFork lsock f = do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)


--------------------------------------------------------------------------------

-- | Attempt to connect to the given host name and port number.
connect :: NS.HostName -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
connect host port = do
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just $ show port)
    E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
       let sockAddr = NS.addrAddress addr
       NS.connect sock sockAddr
       return (sock, sockAddr)
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_ADDRCONFIG]
                            , NS.addrSocketType = NS.Stream }


-- | Attempt to bind a listening 'NS.Socket' on the given host preference and
-- port number.
--
-- 'N.maxListenQueue' is tipically 128, which is too small for high performance
-- servers. So, we use the maximum between 'N.maxListenQueue' and 2048 as the
-- default size of the listening queue.
listen :: HostPreference -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
listen hp port = do
    addrs <- NS.getAddrInfo (Just hints) (hpHostName hp) (Just $ show port)
    let addrs' = case hp of
          HostIPv4 -> prioritize isIPv4addr addrs
          HostIPv6 -> prioritize isIPv6addr addrs
          _        -> addrs
    tryAddrs addrs'
  where
    hints = NS.defaultHints
      { NS.addrFlags = [NS.AI_PASSIVE, NS.AI_NUMERICSERV, NS.AI_NUMERICHOST]
      , NS.addrSocketType = NS.Stream }

    tryAddrs [x]    = useAddr x
    tryAddrs (x:xs) = E.catch (useAddr x) $ \(_ :: E.IOException) -> tryAddrs xs
    tryAddrs _      = error "listen: addrs is empty"

    useAddr addr = E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
      let sockAddr = NS.addrAddress addr
      NS.setSocketOption sock NS.NoDelay 1
      NS.setSocketOption sock NS.ReuseAddr 1
      NS.bindSocket sock sockAddr
      NS.listen sock (max 2048 NS.maxListenQueue)
      return (sock, sockAddr)



newSocket :: NS.AddrInfo -> IO NS.Socket
newSocket addr = NS.socket (NS.addrFamily addr)
                           (NS.addrSocketType addr)
                           (NS.addrProtocol addr)

isIPv4addr, isIPv6addr :: NS.AddrInfo -> Bool
isIPv4addr x = NS.addrFamily x == NS.AF_INET
isIPv6addr x = NS.addrFamily x == NS.AF_INET6

-- | Move the elements that match the predicate closer to the head of the list.
-- Preserve relative order.
prioritize :: (a -> Bool) -> [a] -> [a]
prioritize p = uncurry (++) . partition p

