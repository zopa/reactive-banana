{-----------------------------------------------------------------------------
    reactive-banana
------------------------------------------------------------------------------}
{-# LANGUAGE GADTs, TypeFamilies, TupleSections, EmptyDataDecls,
    TypeSynonymInstances, FlexibleInstances #-}

module Reactive.Banana.Internal.AST where
-- Abstract syntax tree and assorted data types.

import Control.Applicative
import qualified Data.Vault as Vault
import System.IO.Unsafe

import Data.Unique.Really
import Data.Hashable

import qualified Reactive.Banana.Model as Model
import Reactive.Banana.Internal.InputOutput

{-----------------------------------------------------------------------------
    Abstract syntax tree
------------------------------------------------------------------------------}
-- Type families allow us to support multiple tags in the AST
type family   Event    t :: * -> *
type family   Behavior t :: * -> *

-- | Constructors for events.
data EventD t :: * -> * where
    Never     :: EventD t a
    UnionWith :: (a -> a -> a) -> Event t a -> Event t a -> EventD t a
    FilterE   :: (a -> Bool) -> Event t a -> EventD t a
    ApplyE    :: Behavior t (a -> b) -> Event t a -> EventD t b
    AccumE    :: a -> Event t (a -> a) -> EventD t a
    
    InputE    :: InputChannel a   -> EventD t a   -- represent external inputs
    InputPure :: InputChannel (Model.Event a)
              -> EventD t a                       -- input for model implementation

-- | Constructors for behaviors.
data BehaviorD t :: * -> * where
    Stepper :: a -> Event t a -> BehaviorD t a

    InputB :: InputChannel a -> BehaviorD t a -- represent external inputs 

{-----------------------------------------------------------------------------
    Observable sharing
    
    Each constructor is paired with a @Node@ value.
    The @Node@ serves as a unique identifier and stores various keys
    into various vaults.
------------------------------------------------------------------------------}
data Pair f g a = Pair !(f a) (g a)

fstPair :: Pair f g a -> f a
fstPair (Pair x y) = x

-- | Type index indicating expressions with observable sharing
data Expr
type instance Event    Expr = Pair Node (EventD    Expr)
type instance Behavior Expr = Pair Node (BehaviorD Expr)

-- smart constructor that handles observable sharing
shareE :: EventD Expr a -> Event Expr a
shareE e = pair
    where
    {-# NOINLINE pair #-}
    -- mention argument to prevent let-floating
    pair = unsafePerformIO (fmap (flip Pair e) newNode)

shareB :: BehaviorD Expr a -> Behavior Expr a
shareB b = pair
    where
    {-# NOINLINE pair #-}
    pair = unsafePerformIO (fmap (flip Pair b) newNode)

{-----------------------------------------------------------------------------
    Smart constructors and class instances
------------------------------------------------------------------------------}
unE = id; unB = id

{- Note:
There is a fundamental problem with using Unique's for observable sharing.

The problem is the following:

    module Test where ..
    module Implementation where never = sharedE $ Never
    module Data.Unique

Imagine that the  Test  module contains an expression that contains sharing.
The  never  value contains a constant  Unique , which is evaluated as
soon as you evaluate  Test.expression  .
Now, reload the  Test  module. This will reset the counter for Data.Unique,
but it will *not* reset the Unique that is already contained in  never ,
because the CAF  never  itself will not be reset. This invariably leads to
a  Unique  being reused, leading to a program crash.

We solve the problem in Reactive.Banana.InputOutput
by using a better implementation of  Unique .

-}
{- Note:

Another good reason for not sharing `never` is that 
it is *polymorphic*. The shared value may be instantiated to different types,
which is really bad.

-}
never             = shareE $ Never

unionWith f e1 e2 = shareE $ UnionWith f (unE e1) (unE e2)
filterE p e       = shareE $ FilterE p (unE e)
applyE b e        = shareE $ ApplyE (unB b) (unE e)
accumE acc e      = shareE $ AccumE acc (unE e)
inputE i          = shareE $ InputE i
inputPure i       = shareE $ InputPure i

stepperB acc e    = shareB $ Stepper acc (unE e)
inputB i          = shareB $ InputB i

-- functor
mapE f  = applyE (pureB f)

-- applicative functor
pureB x = stepperB x never

applyB :: Behavior Expr (a -> b) -> Behavior Expr a -> Behavior Expr b
applyB (Pair _ (Stepper f fe)) (Pair _ (Stepper x xe)) =
    stepperB (f x) $ mapE (uncurry ($)) pair
    where
    pair = accumE (f,x) $ unionWith (.) (mapE changeL fe) (mapE changeR xe)
    changeL f (_,x) = (f,x)
    changeR x (f,_) = (f,x)
applyB _ _ = error "TODO: Don't know what to do with external behaviors."

mapB f = applyB (pureB f)

{-----------------------------------------------------------------------------
    The 'Node' type is used for observable sharing and must be defined here.
------------------------------------------------------------------------------}
-- | A 'Node' represents a unique identifier for an expression.
-- It actually contains keys for various 'Vault'.
--
-- TODO: Make a special case for the 'Never' constructor,
-- which cannot be shared.
data Node a
    = Node
    { -- use for Reactive.Banana.Internal.PushGraph
      keyValue   :: !(Vault.Key a)
    , keyFormula :: !(Vault.Key (FormulaD Nodes a))
    , keyOrder   :: !Unique
      -- use for Reactive.Banana.Internal.Model
    , keyModelE  :: !(Vault.Key (Model.Event a))
    , keyModelB  :: !(Vault.Key (Model.Behavior a))
    }

newNode :: IO (Node a)
newNode = Node
    <$> Vault.newKey <*> Vault.newKey <*> newUnique
    <*> Vault.newKey <*> Vault.newKey

{-----------------------------------------------------------------------------
    Reactive.Banana.Internal.PushGraph
------------------------------------------------------------------------------}
data Nodes
type instance Event    Nodes = Node
type instance Behavior Nodes = Node

-- | Formula that represents events and behaviors as one entity
data FormulaD t a where
    E :: EventD t a    -> FormulaD t a
    B :: BehaviorD t a -> FormulaD t a

caseFormula :: (EventD t a -> c) -> (BehaviorD t a -> c) -> FormulaD t a -> c
caseFormula e b (E x) = e x
caseFormula e b (B x) = b x

type family Formula t :: * -> *
type instance Formula Expr  = Pair Node (FormulaD Expr)
type instance Formula Nodes = Node

-- Helper class for embedding polymorphically in the type index
class ToFormula t where
    -- e :: Event    t a -> Formula t a
    -- b :: Behavior t a -> Formula t a
    
    ee :: Event t a    -> SomeFormula t
    bb :: Behavior t a -> SomeFormula t

instance ToFormula Expr where
    ee (Pair node e1) = Exists (Pair node $ E e1)
    bb (Pair node b1) = Exists (Pair node $ B b1)

instance ToFormula Nodes where
    ee node = Exists node
    bb node = Exists node


-- | Formula, existentially quantified over the result type
data SomeFormula t where
    Exists :: Formula t a -> SomeFormula t
type SomeNode = SomeFormula Nodes

-- instances to store  SomeNode  in efficient maps
instance Eq SomeNode where
    (Exists x) == (Exists y) = (keyOrder x) == (keyOrder y)
instance Hashable SomeNode where
    hash (Exists x) = hash (keyOrder x)

instance Eq (SomeFormula Expr) where
    (Exists (Pair x _)) == (Exists (Pair y _)) = (keyOrder x) == (keyOrder y)
instance Hashable (SomeFormula Expr) where
    hash (Exists (Pair x _)) = hash (keyOrder x)


