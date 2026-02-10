# 1. Summary

- **Goal:** Let two accounts mutually vouch for each other by each locking an equal **stake**.
- **Windowed handshake:** Once both sides have funded, a **time window** opens. During the window they can:
    - **Steal** (one takes both stakes → no link), or
    - **Close without steal** (both refunded → no link).
        
        After the window ends , either can **finalize** → both refunded and a **link** is added to the queue for processing.
        
- **Graph commitment:** Each finalized link is appended to an **unforged edge queue**. Off-chain provers forge batches of edges and submit a proof to advance the **graphRoot.**

The flow looks like this:

```solidity
Start
  |
  v
A: vouch for B  (A pays stake S)
  |
  |------------------------------.
  |                              |
  v                              v
A: cancel vouch            B: vouch for A (B pays stake S)
(refund A, no link)              |
                                 v
                        MUTUAL FUNDED → Window opens [t0 .. t0+T]
                                 |
               .-----------------+-----------------.
               |                                   |
               |                                   |
     (within window)                       (within window)
        STEAL                                   CLOSE WITHOUT STEAL
        by A or B                               by A or B
        ---------                               -------------------
        - delete pair                           - delete pair
        - thief gets 2S                         - refund A: S
        - no link                               - refund B: S
                                                - no link

                                 |
                                 | (after window ends)
                                 v
                              FINALIZE
                              by either
                              --------
                              - refund A: S
                              - refund B: S
                              - append link to unforged queue

```

