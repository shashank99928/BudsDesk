# The hardware loop

The one procedure that turns a model from read-only into measured.

Everything in `devices/` that is not `confidence: measured` is a guess with a citation, and the
registry refuses to give a guess a write path. That refusal is the product. The only thing that
lifts it is this pass, run by a person with the earbuds in their hand and the log committed
afterwards.

It is not a test suite and it cannot be automated into one. It writes to hardware, it depends on a
human hearing whether something happened, and its most valuable output is sometimes a **negative**
result — "the earbuds acknowledge this and do nothing" is a finding, and a documented one is worth
more than a hopeful button.

---

## Non-negotiables

These are restated from `../SCOPE.md` because a procedure that writes to hardware is exactly where
they get relaxed by accident.

- **Channel 13 (`BESOTA`) is never opened.** Not to check the firmware version, not to "see what it
  says". A failed firmware write bricks the earbuds, and nothing in this repository is worth that.
- **Only setters that have already been observed are sent**, and only from the `Setter` vocabulary in
  `Sources/BudsCore/Protocol.swift`: `0x00` find, `0x01` touch, `0x04` noise control, `0x06`
  equalizer, `0x1b` BassWave. There is no sweeping of setter ids. An id the earbuds send that has
  never been seen is logged and dropped.
- **One write at a time**, each followed by a read-back, each restored before the next.
- **The getter sweep is the only sweep**, it is read-only, and it runs from a committed list.

## Before starting

1. **Nothing else may hold the channel.** It is exclusive and its failure mode is silence: a stale
   holder makes discovery return nothing, which looks exactly like a permission problem. Quit every
   other earbuds app, including the phone's if it is connected.
2. **The earbuds must be awake** — out of the case, or the case open with them in it. The app says
   which it thinks is true; believe it.
3. **`--devices` must name the model.** If it does not, this is a pairing or TCC problem and the loop
   will spend twenty minutes measuring a radio that is not there.
4. **Trace is on**, so the bytes leave a record without anyone copying them:
   ```sh
   BUDSDESK_TRACE=1 BUDSDESK_TRACE_FILE=/tmp/<model>-<date>.log \
     ./BudsDesk.app/Contents/MacOS/BudsDesk
   ```
   It prints where it is writing. If that line is absent, tracing is not on.

## The pass

### 1. Read everything first

Let the app settle and read the whole surface before writing anything: firmware string, codec,
battery per bud, wear, noise mode and level, equalizer preset, BassWave level and its bounds, the
gesture table, the multi-connect list.

Two reasons, both practical. The firmware string is the identity of the unit the log belongs to, and
a capture without it cannot be cited by anything later. And every original value is what the pass has
to restore at the end — reading them afterwards is guessing.

### 2. Write one thing, then read it back

For one capability at a time:

1. **Note the current value.** From the read, not from memory.
2. **Pick a value from the set the hardware has been seen to accept** — a different one from the
   current value, or the write proves nothing. For noise control, walk the levels in turn rather
   than one: on this hardware the four level values are not in strength order and none could have
   been derived from the others.
3. **Write it.**
4. **Read it back.** Only the read-back is evidence. The firmware answers a setter *before* it acts,
   so a write acknowledgement means "I heard you" and nothing more.
5. **Record which of three things happened:**
   - *it stuck* — the read-back shows the new value;
   - *it was refused* — the read-back shows the old value, with no error anywhere;
   - *it went somewhere else* — the read-back shows a third value, which is the most interesting
     result of the three and means the protocol's shape is not what the code thinks it is. Stop and
     capture before doing anything else.
6. **Restore the original value and confirm it came back.** Leaving hardware in a state the app
   cannot describe is the failure this whole repository is arranged against.

### 3. If it stops answering

Do not keep writing. An unresponsive earbud is not an invitation to try the next id — that is how a
read-only model becomes a paperweight. Put them in the case, take them out, reconnect, and start
again from step 1 with whatever is now true. If the state is wrong afterwards, the phone app is the
tool that can fix it, and the log explains what happened.

### 4. Turn the log into a capture

```sh
./Tools/trace-to-capture.py /tmp/<model>-<date>.log \
    --id <model>-<date> --model "<Model>" --vendor <Vendor> \
    --firmware "<the string the earbuds reported>"
```

Then do the part the tool refuses to do, because it is interpretation:

- rename each `rx-NNN` to what it actually is (`anc-reply-nc-high`, `setack-anc`, `eq-push-balanced`);
- say what was set before it arrived, where that is not obvious;
- set `service.rfcommChannel` from the SDP record;
- delete the frames from settings you did not deliberate over, and say in a note that you did.

```sh
./Tools/freeze-captures.sh   # folds every capture into the Swift corpus
swift test                   # the corpus must replay to the state the capture records
```

### 5. Promote the model, or record the negative

Edit `devices/<model>.json`:

- `confidence: measured`, `evidence` naming the capture, `writable: true` — **only** for the
  capabilities that actually stuck. The registry fails to load a profile that claims a write path on
  anything else, which is the point.
- For anything that did not stick, leave the confidence where it was and write the negative result
  into the evidence field. `findMyEarbuds` sits at `read: false, writable: false, confidence:
  inferred` on the measured model precisely because this pass was run and could not promote it: the
  acknowledgement is the same single byte whether or not a tone plays.

A capture that shows a setting being refused is a fixture like any other. It is what stops the next
person from spending an evening rediscovering it.

## What this loop cannot establish, on any model

- **The charging case's charge.** It never appears on this channel. Full captures on a measured unit
  carry exactly two battery slots, left and right, while the wear reply names the case on every poll.
- **Whether a find-my-earbuds tone actually played.** The acknowledgement carries no success or
  failure bit, and the only instrument that could tell is an ear. Do not promote it on a quiet room
  and an assumption.
- **Anything about firmware.** Out of scope permanently, and not narratable as a limitation.
- **What the phone app's server-controlled feature list would enable for this model.** That list is
  per model and server-driven, and this project has no view of it.
