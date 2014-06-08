A brain-dead effectful streaming library, just to see how much we can get away
with, using as little as possible.  I.e., the one-legged centipede version of
conduit. :-)

Features conspicuously lacking:

    - Conduits are not Monads, which omits a lot of important use cases
    - No leftovers

Features surprisingly present:

    - Much simpler types; Void is no longer needed, for example
    - No special operators are needed; conduit pipelines can be expressed
      using only function application ($)
    - Performance beats conduit in simple cases (139ms vs. 259ms)
    - Early termination by consumers
    - Notification of uptream termination
    - monad-control can be used for resource control
    - Prompt finalization
    - Sources are Monoids (though making it an instance takes more work)

What's interesting is that this library is simply a convenience for chaining
monadic folds, and nothing more.  I find it interesting how much of conduit
can be expressed using only that abstraction.

See also my
[blog article](http://newartisans.com/2014/06/simpler-conduit-library/) about
this library.
