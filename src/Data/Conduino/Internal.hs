{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_HADDOCK not-home            #-}

-- |
-- Module      : Data.Conduino.Internal
-- Copyright   : (c) Justin Le 2019
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Internal module exposing the internals of 'Pipe', including its
-- underlying representation and base functor.
--
module Data.Conduino.Internal (
    Pipe(..)
  , PipeF(..)
  , awaitEither
  , yield
  , trimapPipe, mapInput, mapOutput, mapUpRes
  , hoistPipe
  , RecPipe
  , toRecPipe, fromRecPipe
  ) where

import           Control.Monad.Except
import           Control.Monad.Free.Class
import           Control.Monad.Free.TH
import           Control.Monad.RWS
import           Control.Monad.Trans.Free        (FreeT(..))
import           Control.Monad.Trans.Free.Church

-- | Base functor of 'Pipe'.
--
-- A pipe fundamentally has the ability to await and the ability to yield.
-- The other functionality are implemented.
--
-- *  Lifting effects is implemented by the 'MonadTrans' and 'MonadIO'
--    instances that 'FT' gives.
-- *  /Ending/ with a result is implemented by the 'Applicative' instance's
--   'pure' that 'FT' gives.
-- *  Applicative and monadic sequenceing "after a pipe is done" is
--    implemented by the 'Applicative' and 'Monad' instances that 'FT'
--    gives.
--
-- On top of these we implement 'Data.Conduino..|' and other combinators
-- based on the structure that 'FT' gives.  For some functions, it can be
-- easier to use an alternative encoding, 'RecPipe', which is the same
-- thing but explicitly recursive.
data PipeF i o u a =
      PAwaitF (u -> a) (i -> a)
    | PYieldF o a
  deriving Functor

makeFree ''PipeF

-- | Similar to a conduit from the /conduit/ package.
--
-- For a @'Pipe' i o u m a@, you have:
--
-- *  @i@: Type of input stream
-- *  @o@: Type of output stream
-- *  @u@: Type of the /result/ of the upstream pipe (Outputted when
--    upstream pipe finishes)
-- *  @m@: Underlying monad
-- *  @a@: Result type (Outputted when finished)
--
-- Some specializations:
--
-- *  A pipe is a /source/ if @i@ is @()@: it doesn't need anything to go
--    pump out items.  If a pipe is source and @a@ is 'Data.Void.Void', it
--    means that it will produce forever.
--
-- *  A pipe is a /sink/ if @o@ is 'Void.Void': it will never yield
--    anything else downstream.
--
-- *  If a pipe is both a source and a sink, it is an /effect/.
--
-- *  Normally you can ask for input upstream with 'Data.Conduino.await',
--    which returns 'Nothing' if the pipe upstream stops producing.
--    However, if @u@ is 'Data.Void.Void', it means that the pipe upstream
--    will never stop, so you can use 'Data.Conduino.awaitSurely' to get
--    a guaranteed answer.
--
-- Applicative and Monadic sequencing of pipes chains by exhaustion.
--
-- @
-- do pipeX
--    pipeY
--    pipeZ
-- @
--
-- is a pipe itself, that behaves like @pipeX@ until it terminates, then
-- @pipeY@ until it terminates, then @pipeZ@ until it terminates.  The
-- 'Monad' instance allows you to choose "which pipe to behave like next"
-- based on the terminating result of a previous pipe.
--
-- @
-- do x <- pipeX
--    pipeBasedOn x
-- @
--
-- Usually you would use it by chaining together pipes with
-- 'Data.Condunio..|' and then running the result with
-- 'Data.Condunio.runPipe'.
--
-- @
-- 'Data.Conduino.runPipe' $ someSource
--        'Data.Conduino..|' somePipe
--        .| someOtherPipe
--        .| someSink
-- @
--
-- See 'Data.Condunio..|' and 'Data.Condunio.runPipe' for more information
-- on usage.
--
-- For a "prelude" of commonly used 'Pipe's, see
-- "Data.Condunio.Combinators".
--
newtype Pipe i o u m a = Pipe { pipeFree :: FT (PipeF i o u) m a }
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadTrans
    , MonadFree (PipeF i o u)
    , MonadIO
    , MonadState s
    , MonadReader r
    , MonadWriter w
    , MonadError e
    , MonadRWS r w s
    )

instance MonadFail m => MonadFail (Pipe i o u m) where
    fail = lift . fail

-- | Await on upstream output.  Will block until it receives an @i@
-- (expected input type) or a @u@ if the upstream pipe terminates.
awaitEither :: Pipe i o u m (Either u i)
awaitEither = pAwaitF

-- | Send output downstream.
yield :: o -> Pipe i o u m ()
yield = pYieldF

-- | Map over the input type, output type, and upstream result type.
--
-- If you want to map over the result type, use 'fmap'.
trimapPipe
    :: (i -> j)
    -> (p -> o)
    -> (u -> v)
    -> Pipe j p v m a
    -> Pipe i o u m a
trimapPipe f g h = Pipe . transFT go . pipeFree
  where
    go = \case
      PAwaitF a b -> PAwaitF (a . h) (b . f)
      PYieldF a x -> PYieldF (g a) x

-- | Transform the underlying monad of a pipe.
hoistPipe
    :: (Monad m, Monad n)
    => (forall x. m x -> n x)
    -> Pipe i o u m a
    -> Pipe i o u n a
hoistPipe f = Pipe . hoistFT f . pipeFree

-- | (Contravariantly) map over the expected input type.
mapInput :: (i -> j) -> Pipe j o u m a -> Pipe i o u m a
mapInput f = trimapPipe f id id

-- | Map over the downstream output type.
--
-- If you want to map over the result type, use 'fmap'.
mapOutput :: (p -> o) -> Pipe i p u m a -> Pipe i o u m a
mapOutput f = trimapPipe id f id

-- | (Contravariantly) map over the upstream result type.
mapUpRes :: (u -> v) -> Pipe i o v m a -> Pipe i o u m a
mapUpRes = trimapPipe id id

-- | A version of 'Pipe' that uses explicit, concrete recursion instead of
-- church-encoding like 'Pipe'.  Some functions --- especially ones that
-- combine multiple pipes into one --- are easier to implement in this
-- form.
type RecPipe i o u = FreeT (PipeF i o u)

-- | Convert from a 'Pipe' to a 'RecPipe'.  While most of this library is
-- defined in terms of 'Pipe', it can be easier to write certain low-level
-- pipe combining functions in terms of 'RecPipe' than 'Pipe'.
toRecPipe :: Monad m => Pipe i o u m a -> RecPipe i o u m a
toRecPipe = fromFT . pipeFree

-- | Convert a 'RecPipe' back into a 'Pipe'.
fromRecPipe :: Monad m => RecPipe i o u m a -> Pipe i o u m a
fromRecPipe = Pipe . toFT
