{-----------------------------------------------------------------------------
    Reactive-Banana
------------------------------------------------------------------------------}
{-# LANGUAGE GADTs, TypeFamilies, RankNTypes, TypeOperators,
             TypeSynonymInstances, FlexibleInstances,
             ScopedTypeVariables #-}

module Reactive.Banana.Internal.PushGraph (
    -- * Synopsis
    -- | Push-driven implementation.

    compileToAutomaton
    ) where

import Control.Applicative
import Control.Arrow (first)
import Control.Category
import Prelude hiding ((.),id)

import Data.Label
import Data.Maybe
import Data.Monoid (Dual, Endo, Monoid(..))
import qualified Data.Vault as Vault

import Data.Hashable
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set

import Reactive.Banana.Internal.AST
import Reactive.Banana.Internal.InputOutput
import Reactive.Banana.Internal.TotalOrder as TotalOrder

import Debug.Trace

type Map = Map.HashMap
type Set = Set.HashSet

{-----------------------------------------------------------------------------
    Representation of the dependency graph
    and associated lenses
------------------------------------------------------------------------------}
-- Dependency graph
data Graph b
    = Graph
    { grFormulas  :: Formulas                -- formulas for calculation
    , grChildren  :: Map SomeNode [SomeNode] -- reverse dependencies
    , grEvalOrder :: EvalOrder               -- evaluation order
    , grOutput    :: Node b                  -- root node
    , grInputs    :: Inputs                  -- input dispatcher
    }
type Formulas  = Vault.Vault            -- mapping from nodes to formulas
type EvalOrder = TotalOrder SomeNode    -- evaluation order
type Values    = Vault.Vault            -- current event values
type Inputs    = Map Channel [SomeNode] -- mapping from input channels to nodes

-- | Turn a 'Vault.Key' into a lens for the vault
vaultLens :: Vault.Key a -> (Vault.Vault :-> Maybe a)
vaultLens key = lens (Vault.lookup key) (adjust)
    where
    adjust Nothing  = Vault.delete key
    adjust (Just x) = Vault.insert key x 

-- | Formula used to calculate the value at a node.
formula :: Node a -> (Graph b :-> Maybe (FormulaD Nodes a))
formula node = vaultLens (keyFormula node) . formulaLens
    where formulaLens = lens grFormulas (\x g -> g { grFormulas = x})

-- | All nodes that directly depend on this one via the formula.
children :: Node a -> (Graph b :-> [SomeNode])
children node = lens (Map.lookupDefault [] (Exists node) . grChildren)
    (error "TODO: can't set children yet")

-- | Current value for a node.
value :: Node a -> (Values :-> Maybe a)
value node = vaultLens (keyValue node)

{-----------------------------------------------------------------------------
    Operations specific to the DSL
------------------------------------------------------------------------------}
-- | Extract the dependencies of a node from its formula.
-- (boilerplate)
dependencies :: ToFormula t => FormulaD t a -> [SomeFormula t]
dependencies = caseFormula goE goB
    where
    goE :: ToFormula t => EventD t a -> [SomeFormula t]
    goE (Never)             = []
    goE (UnionWith f e1 e2) = [ee e1,ee e2]
    goE (FilterE _ e1)      = [ee e1]
    goE (ApplyE  b1 e1)     = [bb b1, ee e1]
    goE (AccumE  _ e1)      = [ee e1]
    goE _                   = []

    goB :: ToFormula t => BehaviorD t a -> [SomeFormula t]
    goB (Stepper x e1)      = [ee e1]
    goB _                   = []

-- | Nodes whose *current* values are needed to calculate
-- the current value of the given node.
-- (boilerplate)
dependenciesEval :: ToFormula t => FormulaD t a -> [SomeFormula t]
dependenciesEval (E (ApplyE b e)) = [ee e]
dependenciesEval formula          = dependencies formula 

-- | Replace expressions by nodes.
-- (boilerplate)
toFormulaNodes :: FormulaD Expr a -> FormulaD Nodes a
toFormulaNodes = caseFormula (E . goE) (B . goB)
    where
    node :: Pair Node f a -> Node a
    node = fstPair
    
    goE :: forall a. EventD Expr a -> EventD Nodes a
    goE (Never)             = Never
    goE (UnionWith f e1 e2) = UnionWith f (node e1) (node e2)
    goE (FilterE p e)       = FilterE p (node e)
    goE (ApplyE  b e)       = ApplyE (node b) (node e)
    goE (AccumE  x e)       = AccumE x (node e)
    goE (InputE x)          = InputE x

    goB :: BehaviorD Expr a -> BehaviorD Nodes a
    goB (Stepper x e)       = Stepper x (node e)
    goB (InputB x)          = InputB x


-- Evaluation

-- | Evaluate the current value of a given event expression.
calculateE
    :: forall a b.
       (forall e. Node e -> Maybe e)  -- retrieve current event values
    -> (forall b. Node b -> b)        -- retrieve old behavior values
    -> Node a                         -- node ID
    -> EventD Nodes a                 -- formula to evaluate
    -> ( Maybe a                      -- current event value
       , Graph b -> Graph b)          -- (maybe) change formulas in the graph 
calculateE valueE valueB node =
    maybe (Nothing,id) (\(x,f) -> (Just x, f)) . goE
    where
    goE :: EventD Nodes a -> Maybe (a, Graph b -> Graph b)
    goE (Never)             = nothing
    goE (UnionWith f e1 e2) = case (valueE e1, valueE e2) of
        (Just e1, Just e2) -> just $ f e1 e2
        (Just e1, Nothing) -> just e1
        (Nothing, Just e2) -> just e2
        (Nothing, Nothing) -> nothing
    goE (FilterE p e)       = valueE e >>=
        \e -> if p e then just e else nothing
    goE (ApplyE  b e)       = (just . (valueB b $)) =<< valueE e
    goE (AccumE  x e)       = case valueE e of
        Nothing -> just x
        Just f  -> let y = f x in
            Just (y, set (formula node) . Just $ E (AccumE y e))
    goE (InputE _)          = -- input values can be retrieved by node
        just =<< valueE node

just x  = Just (x, id)
nothing = Nothing

-- | Evalute the new value of a given behavior expression
calculateB
    :: forall a b.
       (forall e. Node e -> Maybe e) -- retrieve current event values
    -> Node a                        -- node ID
    -> BehaviorD Nodes a             -- formula to evaluate
    -> Graph b -> Graph b            -- (maybe) change formulas in the graph
calculateB valueE node = maybe id id . goB
    where
    goB :: BehaviorD Nodes a -> Maybe (Graph b -> Graph b) 
    goB (Stepper x e)     =
        (\y -> set (formula node) $ Just $ B (Stepper y e)) <$> valueE e
    goB (InputB x)        = error "TODO"


{-----------------------------------------------------------------------------
    Building the dependency graph
------------------------------------------------------------------------------}
-- | Build full graph from an expression.
buildGraph :: Formula Expr b -> Graph b
buildGraph expr = graph
    where
    graph = Graph
        { grFormulas  = grFormulas
        , grChildren  = buildChildren  (Exists root) grFormulas
        , grEvalOrder = buildEvalOrder graph
        , grOutput    = root
        , grInputs    = buildInputs    (Exists root) grFormulas
        }
    grFormulas = buildFormulas (Exists expr)
    root       = fstPair expr

-- | Build a graph of formulas from an expression
buildFormulas :: SomeFormula Expr -> Formulas
buildFormulas expr =
    unfoldGraphDFSWith leftComposition f expr $ Vault.empty
    where
    f (Exists (Pair node formula)) =
        ( \formulas -> Vault.insert (keyFormula node) formula' formulas
        , dependencies formula )
        where
        formula' = toFormulaNodes formula

-- | Build reverse dependencies, starting from one node.
buildChildren :: SomeNode -> Formulas -> Map SomeNode [SomeNode]
buildChildren root formulas =
    unfoldGraphDFSWith leftComposition f root $ Map.empty
    where
    f (Exists node) = (addChild deps, deps)
        where
        addChild      = concatenate . map (\node -> Map.insertWith (++) node [child])
        child         = Exists node :: SomeNode
        Just formula' = getFormula' node formulas
        deps          = dependencies formula'

getFormula' node formulas = Vault.lookup (keyFormula node) formulas

concatenate :: [a -> a] -> (a -> a)
concatenate = foldr (.) id

-- | Start at some node and update the evaluation order of
-- the node and all of its dependencies.
updateEvalOrder :: SomeNode -> Formulas -> EvalOrder -> EvalOrder
updateEvalOrder = error "TODO"

-- | Build evaluation order from scratch
-- = topological sort
buildEvalOrder :: Graph a -> EvalOrder
buildEvalOrder graph =
    -- we have to build an evaluation order for the root node
    -- and for all the dependencies of a behavior
    TotalOrder.fromAscList $
        concatMap (\x -> unfoldGraphDFSWith leftComposition f x [])
                  (root:findBehaviors)
    where
    root = Exists $ grOutput graph
    f (Exists node) = ((Exists node:), dependenciesEval formula')
        where Just formula' = get (formula node) graph
    
    -- find all the behavior nodes in the graph
    findBehaviors :: [SomeNode]
    findBehaviors = traverseNodes g graph
        where
        g :: Node a -> FormulaD Nodes a -> [SomeNode]
        g node (B _) = [Exists node]
        g _    _     = []

-- | Build collection of input nodes from scratch
buildInputs :: SomeNode -> Formulas -> Inputs
buildInputs root formulas =
    unfoldGraphDFSWith leftComposition f root Map.empty
    where
    f (Exists node) = (addInput, dependencies formula')
        where
        Just formula' = getFormula' node formulas
        addInput :: Inputs -> Inputs
        addInput = case formula' of
            E (InputE i) -> Map.insertWith (++) (getChannel i) [Exists node]
            _            -> id

-- | Traverse all nodes of the graph.
-- The order in which this happens is left unspecified.
traverseNodes
    :: Monoid t
    => (forall a. Node a -> FormulaD Nodes a -> t) -- map nodes to monoid values
    -> Graph b
    -> t
traverseNodes f graph =
    unfoldGraphDFSWith reifyMonoid g (Exists $ grOutput graph)
    where
    g (Exists node) = (f node formula', dependencies formula')
        where Just formula' = get (formula node) graph

{-----------------------------------------------------------------------------
    Generic Graph Traversals
------------------------------------------------------------------------------}
-- | Dictionary for defining monoids on the fly.
data MonoidDict t = MonoidDict t (t -> t -> t)

reifyMonoid :: Monoid t => MonoidDict t
reifyMonoid = MonoidDict mempty mappend

-- | Unfold a graph,
-- i.e. unfold a given state  s  into a concatenation of monoid values
-- while ignoring duplicate states.
-- Depth-first order.
unfoldGraphDFSWith
    :: forall s t. (Hashable s, Eq s) => MonoidDict t -> (s -> (t,[s])) -> s -> t
unfoldGraphDFSWith (MonoidDict empty append) f s = go Set.empty [s]
    where
    go :: Set s -> [s] -> t
    go seen []      = empty
    go seen (x:xs)
        | x `Set.member` seen = go seen xs
        | otherwise           = t `append` go (Set.insert x seen) (ys++xs)
        where
        (t,ys) = f x

-- | Monoid of endomorphisms, leftmost function is applied *last*.
leftComposition :: MonoidDict (a -> a)
leftComposition = MonoidDict id (flip (.))

{-
testDFS :: Int -> [Int]
testDFS = unfoldGraphDFSWith (MonoidDict [] (++)) go
    where go n = ([n],if n <= 0 then [] else [n-2,n-1])
-}

{-----------------------------------------------------------------------------
    Reduction and Evaluation
------------------------------------------------------------------------------}
-- type Queue = [SomeNode]

-- | Perform evaluation steps until all values have percolated through the graph.
evaluate :: Queue q => q SomeNode -> Graph b -> Values -> (Maybe b, Graph b)
evaluate startQueue startGraph startValues =
    (get (value (grOutput startGraph)) endValues, endGraph)
    where    
    (_,endValues,endGraph) =
        until (isEmpty . queue) step (startQueue,startValues,startGraph)
    
    queue (q,_,_) = q
    step  (q,v,g) = (q',v',f g)
        where (q',v',f) = evaluationStep startGraph q v

-- | Perform a single evaluation step.
evaluationStep
    :: forall q b. Queue q
    => Graph b                      -- initial graph shape
    -> q SomeNode                   -- queue of nodes to process
    -> Values                       -- current event values
    -> (q SomeNode, Values, Graph b -> Graph b)
evaluationStep graph queue values = case minView queue of
        Just (Exists node, queue) -> go node queue
        Nothing                   -> error "evaluationStep: queue empty"
    where
    go :: forall a b.
        Node a -> q SomeNode -> (q SomeNode, Values, Graph b -> Graph b)
    go node queue =
        let -- lookup functions
            valueE :: forall e. Node e -> Maybe e
            valueE node = get (value node) values
            valueB :: forall b. Node b -> b
            valueB node = case get (formula node) graph of
                Just (B (Stepper b _)) -> b
                _               -> error "evaluationStep: behavior not found"

            err = error "evaluationStep: formula not found"
        in -- evaluation
            case maybe err id $ get (formula node) graph of
            B formulaB ->   -- evalute behavior
                (queue, values, calculateB valueE node formulaB)
            E formulaE ->   -- evaluate event
                let -- calculate current value
                    (maybeval, f) =
                        calculateE valueE valueB node formulaE
                    -- set value if applicable
                    setValue = case maybeval of
                        Just x  -> set (value node) (Just x)
                        Nothing -> id
                    -- evaluate children only if node doesn't return Nothing
                    setQueue = case maybeval of
                        Just _  -> insertList $ get (children node) graph
                        Nothing -> id
                in (setQueue queue, setValue values, f)

{-----------------------------------------------------------------------------
    Convert into an automaton
------------------------------------------------------------------------------}
compileToAutomaton :: Event Expr b -> IO (Automaton b)
compileToAutomaton expr = return $ fromStateful automatonStep $ buildGraph (e expr)
    where
    e :: Event Expr b -> Formula Expr b
    e (Pair n x) = Pair n (E x)
    
-- single step function of the automaton
automatonStep :: [InputValue] -> Graph b -> IO (Maybe b, Graph b)
automatonStep inputs graph = return (b, graph')
    where    
    -- figure out nodes corresponding to input values
    inputNodes :: [(InputValue, SomeNode)]
    inputNodes =
        [ (i, node)
        | i <- inputs
        , nodes <- maybeToList $ Map.lookup (getChannel i) (grInputs graph)
        , node  <- nodes]

    -- fill up values for start/input nodes
    startValues = foldr insertInput Vault.empty inputNodes
    -- insert a single input into the start values
    insertInput :: (InputValue, SomeNode) -> Values -> Values
    insertInput (i,somenode) = maybe id id $
        withInputNode somenode (\node channel ->
            maybe id (Vault.insert (keyValue node)) $ fromValue channel i
            )  

    -- unpack  InputE  node if applicable
    withInputNode :: SomeNode
        -> (forall a. Node a -> InputChannel a -> b) -> Maybe b
    withInputNode somenode f = case somenode of
        Exists node ->
            let theformula = get (formula node) graph
            in case theformula of
                Just (E (InputE channel)) -> Just $ f node channel
                _ -> Nothing
    
    -- perform evaluation
    (b,graph') = withTotalOrder (grEvalOrder graph) $ \qempty ->
        evaluate (insertList (map snd inputNodes) qempty) graph startValues



