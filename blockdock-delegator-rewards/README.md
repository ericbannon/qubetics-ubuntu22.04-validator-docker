As part of our commitment to being opensource, transparent, and reproducible, 100% of our validator commissions will be redistributed back to our delegators every month, proportional to their stake. This will begin happening immediately upon when the block on rewards height reaches 2,400,000. 

This means if you delegate to The Block Dock Validator, you not only earn normal staking rewards,
but also share in our validator’s commissions — fairly, automatically, and every month.

### Plan only (no sends, no withdraw):

```
FROM=main-wallet \
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