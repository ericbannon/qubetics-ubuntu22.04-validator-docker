As part of our commitment to being opensource, transparent, and reproducible, 100% of our validator commissions will be redistributed back to our delegators every month, proportional to their stake. This will begin happening immediately upon when the block on rewards height reaches 2,400,000. 

This means if you delegate to The Block Dock Validator, you not only earn normal staking rewards,
but also share in our validator’s commissions — fairly, automatically, and every month.

### Plan only (no sends, no withdraw):

```
FROM=qubetics18llj8eqh9k9mznylk8svrcc63ucf7y2rkyqm2m \
HOME_DIR=/mnt/nvme/qubetics \
DRY_RUN=false \
./distribute_commissions.sh --only-plan
```

### Withdraw + plan (will prompt; continues if locked):

```
FROM=main-wallet \
HOME_DIR=/mnt/nvme/qubetics \
DRY_RUN=false \
./distribute_commissions.sh --withdraw --only-plan
```

### Full run (withdraw + distribute + CSV):

```
FROM=main-wallet \
HOME_DIR=/mnt/nvme/qubetics \
DRY_RUN=false \
GAS_PRICES=0.025tics \
./distribute_commissions.sh --withdraw --export plan_$(date +%Y-%m).csv
```

## Example Output

```
FROM=qubetics18llj8eqh9k9mznylk8svrcc63ucf7y2rkyqm2m \
HOME_DIR=/mnt/nvme/qubetics \
DRY_RUN=false \
./distribute_commissions.sh --only-plan
[INFO] Fetching delegators...
[INFO] Delegators: 8 | Total stake: xxxxxxxxxxxxxxxxxx tics
[INFO] FROM address: qubetics18lljzyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
[INFO] Querying spendable balance for qubetics18lljzyyyyyyyyyyyyyyyyyyyyyyyyyyyyy ...
[INFO] Spendable: 71458995198161154753 tics
[INFO] Distribution pool: 71458995198160660000 tics (spendable 71458995198161154753)
[INFO] Eligible payouts: 8 | Sum: 71458995198160660000 tics | Leftover: 0 tics

Delegator                                               Amount (tics)
-----------------------------------------------  --------------------
qubetics1......................................  xxxxxxxxxxxxxxxxxxxx
qubetics1......................................  xxxxxxxxxxxxxxxxxxxx
qubetics1......................................   xxxxxxxxxxxxxxxxxxx
qubetics1......................................   xxxxxxxxxxxxxxxxxxx
qubetics1......................................     xxxxxxxxxxxxxxxxx
qubetics1......................................     xxxxxxxxxxxxxxxxx
qubetics1......................................         xxxxxxxxxxxxx
qubetics1......................................     xxxxxxxxxxxxxxxxx
TOTAL                                            xxxxxxxxxxxxxxxxxxxx

[INFO] Plan only. Exiting.
````