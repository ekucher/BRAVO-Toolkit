# BRAVO_DATA_RESTORE 5.1.0-rc.2 — DEV-LIMS Acceptance Evidence

## Candidate identity

Candidate:
047d321958d30eb7043d202dab254d95bcf6bd96

Functional source:
ac6eb6c8190e22cedd66ab7305b2a27a62f25955

packageVersion:
5.1.0-rc.2

releaseChannel:
prerelease

buildId:
ac6eb6c

Generation:
20260814_230004

Runtime:
E:\ARCHIV_LIMS_MONOLITH

Host:
DEV-LIMS

PowerShell:
5.1

## Acceptance summary

PHASE 0:
PASS

PHASE 1–4:
PASS

B15 single-component InPlace:
PASS

B16 InPlace All:
PASS

B19 single-component rollback:
PASS

B20 cross-component rollback:
BLOCKED

B17:
NOT STARTED

B21:
NOT STARTED

B22:
NOT STARTED

## B15 evidence

Component:
BRAVOEXCH

Mode:
InPlace

Exit:
0

Health:
PASS

Prerestore:
E:\LIMS\bravoexch.prerestore_20260815_141429

BLOG +48-byte drift:
EXPECTED SERVICE ACTIVITY

Пояснення:
lims.~lgx змінився всередині BRAVO shutdown window;
DataRestore log не містив BLOG references.

## B16 evidence

Component:
All

Exit:
0

MODEL:
PASS

BLOG:
PASS

BRAVOEXCH:
PASS

Prerestore:
E:\LIMS\Model.prerestore_20260815_154407
E:\LIMS\BLOG.prerestore_20260815_154407
E:\LIMS\bravoexch.prerestore_20260815_154407

B15 BRAVOEXCH prerestore:
PRESERVED

Services:
RESTORED

Health:
PASS

BRAVO.config:
UNCHANGED

Runtime Guard:
PASS

Canonical generation:
UNCHANGED

## B19 evidence

Fixture:
MODEL / InPlace / TimeoutSeconds=5

Expected exit:
43

Actual exit:
43

Mutation before failure:
YES

Move-aside:
E:\LIMS\Model
->
E:\LIMS\Model.prerestore_20260815_162151

Failure:
timeout during MODEL extraction

Rollback invoked:
YES

Rollback completed:
YES

Native marker:
"Rollback виконано: E:\LIMS\Model повернуто до стану перед відновленням"

MODEL pre/post:
files 536 -> 536
bytes 9024112238 -> 9024112238
fingerprint MATCH

New B19 prerestore after rollback:
NONE
(expected)

Services:
RESTORED

Config/canonical:
UNCHANGED

BLOG delta:
+48 bytes

Changed file:
E:\LIMS\BLOG\lims.~lgx

LastWriteTime:
2026-08-15 16:21:57.578 +03:00

Service timing:
stop requested 16:21:56.703
stopped        16:21:57.766

DataRestore BLOG references:
NONE

Classification:
EXPECTED SERVICE ACTIVITY

Wrapper strict BLOG fingerprint:
FALSE POSITIVE

B19 final:
PASS

## B20

Status:
BLOCKED

Причина:

generation 20260814_230004 має component timing profile,
за якого глобальний TimeoutSeconds не дозволяє deterministic
отримати late-component failure після успішного завершення
попередніх component restores.

Безпечний альтернативний mechanism вимагав би зміни
candidate/config/canonical data/live ACL або іншого
неприйнятного fault injection.

Тому B20 не запускався.

Не класифікувати BLOCKED як PASS.

## Final safety state

BRAVO.config SHA256:
B0255D59E3AF56297DF07ABFB36A6EA3750BED6808350B8E7AE5352C52CF9E1A

Runtime Guard:
IsValid=True
ShouldBlock=False

Canonical manifest:
UNCHANGED

Canonical archives:
UNCHANGED

Services:
BRAVO Running
tapisrv Stopped
vmickvpexchange Stopped

Temporary acceptance tasks:
NONE

Secrets exposed:
NO

Existing prerestore evidence:
PRESERVED

## Final verdict

NO-GO — DO NOT START ADVANCED FAILURE ACCEPTANCE

Reason:

B19 PASS,
but B20 BLOCKED.

Cross-component rollback atomicity therefore remains
not empirically proven by a safe deterministic DEV-LIMS fault injection.

This verdict is NOT:
- PROMOTE;
- stable approval;
- release authorization.

## Deferred / not executed

B17
B21
B22

No commit/push/tag/release was performed as part of this acceptance.
