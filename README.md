# distributed
CH/OTP Test Task

Instead of concentrating on speed, I decided to instead concentrate on a modular approach which
(hopefully) guarantees correctness in a "perfect" network. If communication breaks down,
no result will be reported.

The idea is to first implement a modular "broadcasting" layer on top of an arbitrary totally connected
network of Cloud Haskell nodes - this abstraction is done in Distributed.Broadcast.

Using that abstraction, which provides totally ordered broadcasting on top of "normal" Cloud Haskell
processes, it is relatively straight forward to implement the program.

I decided to accumulate results permanently (in constrast to ordering the messages later, during the
waiting period). My reasoning for this design descision is that otherwise, it's difficult to run the
algorithm for a long time without creating a space leak.

The program is started by running the shell script test.sh, which contains an example configuration
of ten nodes on the local machine.

Unfortunately, I am not sure how to do this with different setup strategies.
