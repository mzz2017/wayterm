# Store Entitlement Replay Risk Note

## Why This Exists

Public 2026 reports described a ChatGPT iOS subscription abuse pattern where an
intercepted Apple purchase credential was allegedly replayed to activate paid
access on multiple accounts. Treat those reports as third-party reports, not an
official postmortem, but keep the underlying failure mode in mind:

```text
valid Apple purchase credential + valid app session = paid access
```

That check is not enough for account-backed entitlements. The purchase evidence
must be bound to the account that receives access.

## Current VVTerm Position

VVTerm currently grants Pro from local StoreKit 2 state, not from a VVTerm
server endpoint:

- purchases use StoreKit verification before finishing transactions
- entitlement refresh reads StoreKit current entitlements
- restore refreshes StoreKit/App Store state
- there is no app-owned backend that accepts a receipt, JWS transaction, or
  signed purchase blob and converts it into server-side Pro

So the specific "intercept credential and replay it against another VVTerm
account" class is not currently exposed by VVTerm's Store architecture.

## Guardrail

Do not add a receipt upload, signed-transaction upload, "subscription upgrade",
account-backed Pro, cross-device server entitlement, or web-account purchase
bridge unless the design explicitly prevents replay across accounts.

For any future server-backed entitlement path, review must confirm:

- Apple-signed purchase data is validated server-side with App Store Server API
  or Apple's server library.
- `appAccountToken`, when available, is generated per VVTerm account and checked
  against the account receiving access.
- `transactionId` is single-use for activation and idempotent only for the same
  account.
- `originalTransactionId` subscription lineage cannot silently move to another
  VVTerm account.
- restore refreshes the original owner; it does not become an automatic account
  transfer flow.
- refunds, revocations, expiration, billing retry failure, and family sharing
  removal revoke or downgrade server access.
- behavior tests prove one Apple purchase cannot activate two VVTerm accounts.

Keep review mode separate from customer entitlement. It should remain local,
time-limited, and unsuitable as a server or synced entitlement source.

## References

- Apple App Store Server API:
  https://developer.apple.com/documentation/appstoreserverapi
- Apple `appAccountToken`:
  https://developer.apple.com/documentation/appstoreserverapi/appaccounttoken
- Apple receipt validation guidance:
  https://developer.apple.com/documentation/storekit/validating-receipts-with-the-app-store
- Apple WWDC25 App Store server APIs session:
  https://developer.apple.com/videos/play/wwdc2025/249/
