[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)][switch]$Preflight,
    [Parameter(ParameterSetName = 'Prepare', Mandatory = $true)][switch]$Prepare,
    [Parameter(ParameterSetName = 'Approve', Mandatory = $true)][switch]$Approve,
    [Parameter(ParameterSetName = 'Activate', Mandatory = $true)][switch]$Activate,
    [Parameter(ParameterSetName = 'Validate', Mandatory = $true)][switch]$Validate,
    [Parameter(ParameterSetName = 'Accept', Mandatory = $true)][switch]$Accept,
    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)][switch]$Rollback,
    [Parameter(ParameterSetName = 'Status', Mandatory = $true)][switch]$Status,

    # Каталог реального встановлення BRAVO-Toolkit на pilot-сервері.
    # Обов'язковий для всіх режимів, крім -Status без -EvidenceDir.
    [string]$InstallRoot,

    # Каталог, з якого запущений цей скрипт (артефакт). За замовчуванням —
    # каталог самого скрипта, що коректно для звичайного розпакованого
    # артефакту.
    [string]$ArtifactRoot = $PSScriptRoot,

    # Корінь, де створюються нові каталоги доказів (-Prepare). Типово —
    # ProgramData: стабільне, завжди записуване місце окремо від
    # InstallRoot (який може бути Program Files з обмеженим ACL).
    [string]$EvidenceRoot = (Join-Path $env:ProgramData 'BRAVO\ConfigV2PilotEvidence'),

    # Конкретний каталог доказів для -Approve/-Activate/-Validate/-Accept/
    # -Rollback/-Status. Для -Prepare — ігнорується (створюється новий).
    [string]$EvidenceDir,

    [string]$ServerId = $env:COMPUTERNAME,

    # -Approve: SHA-256 candidate, показаний оператору після -Prepare.
    # Активація без відповідного затвердженого hash неможлива.
    [string]$ApprovedCandidateHash,

    [string]$Operator = $env:USERNAME,

    # -Preflight: опційно зберегти результат як окремий звіт (Preflight
    # сам по собі лишається read-only й нічого не персистить без цього).
    [string]$ReportPath
)

# Start-BRAVOConfigV2Pilot.ps1 — тонкий CLI-диспетчер контрольованого
# реального pilot Configuration v2. Уся логіка — у
# BRAVOConfigV2Pilot.Runtime.ps1 (dot-sourced нижче); цей файл лише
# розбирає режим і викликає відповідну функцію. PowerShell 5.1.
#
# Автоматизує прийнятий оператором вручну runbook
# docs\BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md — жодного
# нового Configuration v2 алгоритму тут немає, лише orchestration +
# evidence + state machine + rollback safety навколо canonical
# інструментів, встановлених на самому -InstallRoot.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$runtimeLibPath = Join-Path $PSScriptRoot 'BRAVOConfigV2Pilot.Runtime.ps1'
if (-not (Test-Path -LiteralPath $runtimeLibPath -PathType Leaf)) {
    Write-Error "Не знайдено $runtimeLibPath — артефакт пошкоджений або неповний."
    exit 1
}
. $runtimeLibPath

function Resolve-BRAVOPilotFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath($Path)
}

try {
    switch ($PSCmdlet.ParameterSetName) {

        'Preflight' {
            if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw "-InstallRoot є обов'язковим для -Preflight." }
            $result = Invoke-BRAVOPilotPreflight -InstallRoot (Resolve-BRAVOPilotFullPath $InstallRoot) -ArtifactRoot (Resolve-BRAVOPilotFullPath $ArtifactRoot) -EvidenceRoot $EvidenceRoot

            foreach ($check in $result.Checks) {
                $marker = if ($check.Pass) { '[OK]' } elseif ($check.Blocking) { '[FAIL]' } else { '[WARN]' }
                Write-Host ("{0,-7} {1}: {2}" -f $marker, $check.Name, $check.Detail)
            }
            Write-Host ''
            if ($result.Pass) {
                Write-Host '[SUCCESS] Preflight PASSED — сервер готовий до -Prepare.' -ForegroundColor Green
            } else {
                Write-Host ("[FAILED] Preflight FAILED — блокуючі перевірки: {0}" -f ([string]::Join(', ', $result.FailedBlockingChecks))) -ForegroundColor Red
            }

            if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
                Write-BRAVOPilotEvidenceJson -Path $ReportPath -Object $result
                Write-Host "Звіт збережено: $ReportPath"
            }
            if (-not $result.Pass) { exit 1 }
            exit 0
        }

        'Prepare' {
            if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw "-InstallRoot є обов'язковим для -Prepare." }
            $resolvedInstallRoot = Resolve-BRAVOPilotFullPath $InstallRoot
            $resolvedArtifactRoot = Resolve-BRAVOPilotFullPath $ArtifactRoot

            # НЕ називати цю змінну $preflight: PowerShell-змінні
            # регістронезалежні, а скрипт уже має типізований [switch]$Preflight
            # (параметр-набір 'Preflight') — присвоєння PSCustomObject у змінну
            # з тим самим ім'ям (без урахування регістру) намагається
            # конвертувати результат у SwitchParameter і кидає виняток.
            $preflightResult = Invoke-BRAVOPilotPreflight -InstallRoot $resolvedInstallRoot -ArtifactRoot $resolvedArtifactRoot -EvidenceRoot $EvidenceRoot
            if (-not $preflightResult.Pass) {
                Write-Host ("[FAILED] Preflight не пройдено — блокуючі перевірки: {0}. -Prepare зупинено." -f ([string]::Join(', ', $preflightResult.FailedBlockingChecks))) -ForegroundColor Red
                exit 1
            }

            $dir = New-BRAVOPilotEvidenceDirectory -EvidenceRoot $EvidenceRoot -ServerId $ServerId
            Write-BRAVOPilotEvidenceJson -Path (Join-Path $dir 'artifact-manifest.json') -Object (
                Get-Content -LiteralPath (Join-Path $resolvedArtifactRoot 'manifest\PILOT_MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            )
            Write-BRAVOPilotEvidenceJson -Path (Join-Path $dir 'preflight.json') -Object $preflightResult
            Set-BRAVOPilotState -EvidenceDir $dir -State 'PreflightPassed' | Out-Null

            Invoke-BRAVOPilotConfigSnapshot -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $dir 'before.snapshot.json') | Out-Null
            Invoke-BRAVOPilotHealthSnapshot -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $dir 'health.before.log') | Out-Null
            Set-BRAVOPilotState -EvidenceDir $dir -State 'BaselineCaptured' | Out-Null

            $candidatePath = Join-Path $dir 'BRAVO.local.config.candidate'
            $delta = Invoke-BRAVOPilotDeltaGeneration -InstallRoot $resolvedInstallRoot -CandidatePath $candidatePath
            Copy-Item -LiteralPath $candidatePath -Destination (Join-Path $dir 'delta.preview.txt') -ErrorAction Stop
            Write-BRAVOPilotEvidenceJson -Path (Join-Path $dir 'delta.metadata.json') -Object $delta
            Set-BRAVOPilotState -EvidenceDir $dir -State 'DeltaGenerated' -ExtraFields @{ CandidatePath = $candidatePath; CandidateHash = $delta.Sha256 } | Out-Null

            Write-Host "[SUCCESS] Prepare завершено."
            Write-Host "  EvidenceDir:    $dir"
            Write-Host "  Candidate:      $candidatePath"
            Write-Host "  Candidate hash: $($delta.Sha256)"
            Write-Host ''
            Write-Host "Перегляньте $((Join-Path $dir 'delta.preview.txt')) — це НЕ механічний крок."
            Write-Host "Після перегляду: -Approve -EvidenceDir `"$dir`" -ApprovedCandidateHash $($delta.Sha256)"
            exit 0
        }

        'Approve' {
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { throw "-EvidenceDir є обов'язковим для -Approve." }
            if ([string]::IsNullOrWhiteSpace($ApprovedCandidateHash)) { throw "-ApprovedCandidateHash є обов'язковим — approval прив'язаний до hash показаного candidate (NO ACTIVATION без нього)." }
            Assert-BRAVOPilotState -EvidenceDir $EvidenceDir -RequiredState @('DeltaGenerated', 'Reviewed') -Operation '-Approve' | Out-Null

            $state = Get-BRAVOPilotState -EvidenceDir $EvidenceDir
            $candidatePath = [string]$state.CandidatePath
            $approval = Approve-BRAVOPilotCandidate -EvidenceDir $EvidenceDir -CandidatePath $candidatePath -ApprovedCandidateHash $ApprovedCandidateHash -Operator $Operator
            Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Reviewed' -ExtraFields @{ CandidatePath = $candidatePath; CandidateHash = $approval.CandidateHash } | Out-Null

            Write-Host "[SUCCESS] Candidate затверджено оператором '$Operator' (hash $($approval.CandidateHash))."
            Write-Host "Наступний крок: -Activate -InstallRoot `"$InstallRoot`" -EvidenceDir `"$EvidenceDir`""
            exit 0
        }

        'Activate' {
            if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw "-InstallRoot є обов'язковим для -Activate." }
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { throw "-EvidenceDir є обов'язковим для -Activate." }
            $resolvedInstallRoot = Resolve-BRAVOPilotFullPath $InstallRoot

            # Взаємне виключення з будь-яким іншим одночасним -Activate/
            # -Rollback над цим самим -InstallRoot (§concurrency-triage):
            # обидві операції мутують BRAVO.local.config/BRAVO.config через
            # окремі атомарні записи, які без цього логу могли б чергуватись
            # у несумісну комбінацію файлів на диску.
            $pilotLock = Enter-BRAVOPilotInstallRootLock -InstallRoot $resolvedInstallRoot
            try {
                # 'Activated' також дозволений: повторний -Activate уже
                # активованого candidate — ідемпотентна операція (§27) —
                # Invoke-BRAVOPilotAtomicActivation виявляє однаковий hash і
                # не пише файл вдруге.
                $state = Assert-BRAVOPilotState -EvidenceDir $EvidenceDir -RequiredState @('Reviewed', 'Activated') -Operation '-Activate'
                $candidatePath = [string]$state.CandidatePath
                $approvedHash = [string]$state.CandidateHash

                # Ідемпотентний повторний -Activate: якщо на сервері вже діє
                # BRAVO.local.config з тим самим SHA-256, що й candidate, — це
                # чистий no-op, і НОВИЙ backup створювати не можна. Інакше
                # повторний виклик у ту саму секунду (yyyyMMdd-HHmmss) міг би
                # вдруге записати той самий backup-каталог і пошкодити
                # backup-manifest.json (self-referential hash mismatch), а
                # головне — підмінити BackupDir у стані на backup ВЖЕ
                # активованого стану замість справжнього pre-activation backup,
                # яким має користуватись -Rollback.
                if ((Test-Path -LiteralPath (Join-Path $EvidenceDir 'activation.json') -PathType Leaf) -and
                    (Test-BRAVOPilotActivationIsNoOp -InstallRoot $resolvedInstallRoot -CandidatePath $candidatePath)) {
                    Write-Host "[SUCCESS] Активація — no-op: BRAVO.local.config на сервері вже мав такий самий SHA-256. Backup не дублюється."
                    Write-Host "Наступний крок: -Validate -InstallRoot `"$InstallRoot`" -EvidenceDir `"$EvidenceDir`""
                    exit 0
                }

                $backup = New-BRAVOPilotBackup -InstallRoot $resolvedInstallRoot -EvidenceDir $EvidenceDir
                Test-BRAVOPilotBackupIntegrity -BackupDir $backup.BackupDir | Out-Null
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'BackupCreated' -ExtraFields @{ CandidatePath = $candidatePath; CandidateHash = $approvedHash; BackupDir = $backup.BackupDir } | Out-Null

                # Якщо активація впаде тут, стан МАЄ перейти в 'Failed' (легальний
                # перехід з 'BackupCreated' — уже описаний у
                # $script:BRAVOPilotStateTransitions), інакше metadata.json
                # назавжди лишається на 'BackupCreated', і повторний -Activate
                # неможливий (Assert-BRAVOPilotState для -Activate вимагає
                # 'Reviewed'/'Activated'), а зовнішній catch унизу файлу лише
                # друкує помилку й виходить, не торкаючись стану. Backup уже
                # верифікований (Test-BRAVOPilotBackupIntegrity вище) і
                # лишається валідним — відновлення через -Rollback доступне
                # незалежно від значення State (Invoke-BRAVOPilotRollback шукає
                # каталог backup-*, а не читає metadata.json).
                try {
                    $activation = Invoke-BRAVOPilotAtomicActivation -InstallRoot $resolvedInstallRoot -CandidatePath $candidatePath -EvidenceDir $EvidenceDir -ApprovedCandidateHash $approvedHash
                } catch {
                    Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Failed' -ExtraFields @{ CandidatePath = $candidatePath; CandidateHash = $approvedHash; BackupDir = $backup.BackupDir } | Out-Null
                    throw "$($_.Exception.Message) Backup перевірено й доступний у '$($backup.BackupDir)' — виконайте -Rollback -InstallRoot `"$InstallRoot`" -EvidenceDir `"$EvidenceDir`"."
                }
                Write-BRAVOPilotEvidenceJson -Path (Join-Path $EvidenceDir 'activation.json') -Object $activation
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Activated' -ExtraFields @{ CandidatePath = $candidatePath; CandidateHash = $approvedHash; BackupDir = $backup.BackupDir } | Out-Null

                if ($activation.NoOp) {
                    Write-Host "[SUCCESS] Активація — no-op: BRAVO.local.config на сервері вже мав такий самий SHA-256."
                } else {
                    Write-Host "[SUCCESS] BRAVO.local.config активовано атомарно: $($activation.TargetPath)"
                }
                Write-Host "Наступний крок: -Validate -InstallRoot `"$InstallRoot`" -EvidenceDir `"$EvidenceDir`""
                exit 0
            } finally {
                Exit-BRAVOPilotInstallRootLock -Mutex $pilotLock
            }
        }

        'Validate' {
            if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw "-InstallRoot є обов'язковим для -Validate." }
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { throw "-EvidenceDir є обов'язковим для -Validate." }
            $resolvedInstallRoot = Resolve-BRAVOPilotFullPath $InstallRoot
            # 'Validated' також дозволений: повторний -Validate — чисте
            # повторне читання/верифікація, без мутуючих побічних ефектів
            # (§27 ідемпотентність) — детермінований, безпечний повторний
            # прогін тих самих read-only перевірок.
            $state = Assert-BRAVOPilotState -EvidenceDir $EvidenceDir -RequiredState @('Activated', 'Validated') -Operation '-Validate'

            $allPass = $true

            $validateOnly = Invoke-BRAVOPilotValidateOnly -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $EvidenceDir 'validate-only.log')
            Write-Host ("{0} ValidateOnly (exit {1})" -f $(if ($validateOnly.Pass) { '[OK]' } else { '[FAIL]' }), $validateOnly.ExitCode)
            $allPass = $allPass -and $validateOnly.Pass

            $afterSnapshot = Invoke-BRAVOPilotConfigSnapshot -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $EvidenceDir 'after.snapshot.json')
            $parity = Invoke-BRAVOPilotSemanticParity -InstallRoot $resolvedInstallRoot `
                -BeforePath (Join-Path $EvidenceDir 'before.snapshot.json') `
                -AfterPath (Join-Path $EvidenceDir 'after.snapshot.json') `
                -OutputPath (Join-Path $EvidenceDir 'parity.json')
            Write-Host ("{0} Semantic parity BEFORE==AFTER" -f $(if ($parity.Pass) { '[OK]' } else { '[FAIL]' }))
            $allPass = $allPass -and $parity.Pass

            $selfTest = Invoke-BRAVOPilotSelfTest -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $EvidenceDir 'self-test.log')
            Write-Host ("{0} BRAVO_SELF_TEST.ps1 (exit {1}, НЕДОСТУПНО={2}, FAIL={3})" -f $(if ($selfTest.Pass) { '[OK]' } else { '[FAIL]' }), $selfTest.ExitCode, $selfTest.HasUnavailable, $selfTest.HasFail)
            $allPass = $allPass -and $selfTest.Pass

            $beforeHealthLines = @(Get-Content -LiteralPath (Join-Path $EvidenceDir 'health.before.log') -Encoding UTF8 -ErrorAction SilentlyContinue)
            $health = Invoke-BRAVOPilotHealthCheck -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $EvidenceDir 'health.log') -BeforeLines $beforeHealthLines
            Write-Host ("{0} Health (нових деградацій: {1})" -f $(if ($health.Pass) { '[OK]' } else { '[FAIL]' }), @($health.NewDegradations).Count)
            $allPass = $allPass -and $health.Pass

            $archiveSmoke = Invoke-BRAVOPilotArchiveSmoke -InstallRoot $resolvedInstallRoot -OutputPath (Join-Path $EvidenceDir 'archive-smoke.log')
            Write-Host ("{0} Archive smoke (BRAVO_DRY_RUN.ps1, exit {1})" -f $(if ($archiveSmoke.Pass) { '[OK]' } else { '[FAIL]' }), $archiveSmoke.ExitCode)
            $allPass = $allPass -and $archiveSmoke.Pass

            if ($allPass) {
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Validated' -ExtraFields @{ CandidatePath = [string]$state.CandidatePath; CandidateHash = [string]$state.CandidateHash; BackupDir = [string]$state.BackupDir } | Out-Null
                Write-Host ''
                Write-Host '[SUCCESS] Усі перевірки Validate пройдено.' -ForegroundColor Green
                Write-Host "Наступний крок: -Accept -EvidenceDir `"$EvidenceDir`" (або -Rollback у разі сумнівів)"
                exit 0
            } else {
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Failed' -ExtraFields @{ CandidatePath = [string]$state.CandidatePath; CandidateHash = [string]$state.CandidateHash; BackupDir = [string]$state.BackupDir } | Out-Null
                Write-Host ''
                Write-Host '[FAILED] Не всі перевірки Validate пройдено. РЕКОМЕНДАЦІЯ: -Rollback.' -ForegroundColor Red
                exit 1
            }
        }

        'Accept' {
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { throw "-EvidenceDir є обов'язковим для -Accept." }
            Assert-BRAVOPilotState -EvidenceDir $EvidenceDir -RequiredState @('Validated') -Operation '-Accept' | Out-Null

            $validateOnly = Get-Content -LiteralPath (Join-Path $EvidenceDir 'validate-only.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            $parity = Get-Content -LiteralPath (Join-Path $EvidenceDir 'parity.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            $selfTestLog = @(Get-Content -LiteralPath (Join-Path $EvidenceDir 'self-test.log') -Encoding UTF8 -ErrorAction Stop)
            $backupManifestExists = @(Get-ChildItem -LiteralPath $EvidenceDir -Directory -Filter 'backup-*').Count -gt 0
            $humanReviewExists = Test-Path -LiteralPath (Join-Path $EvidenceDir 'human-review.json') -PathType Leaf

            # PreflightPass — з ФАКТИЧНОГО збереженого результату, а не
            # припущення: -Prepare зупиняється (exit 1, preflight.json НЕ
            # пишеться) до проходження блокуючих Preflight-перевірок, тому
            # ArtifactIntegrityPass (файл існує) НЕ гарантує сам собою, що
            # .Pass у ньому — true, якщо код -Prepare колись зміниться.
            $preflightJson = $null
            try {
                $preflightRaw = Get-Content -LiteralPath (Join-Path $EvidenceDir 'preflight.json') -Raw -Encoding UTF8 -ErrorAction Stop
                $preflightJson = $preflightRaw | ConvertFrom-Json
            } catch {
                $preflightJson = $null
            }

            $criteria = @{
                ArtifactIntegrityPass    = (Test-Path -LiteralPath (Join-Path $EvidenceDir 'preflight.json') -PathType Leaf)
                PreflightPass            = ($null -ne $preflightJson -and [bool]$preflightJson.Pass)
                BaselineCaptured         = (Test-Path -LiteralPath (Join-Path $EvidenceDir 'before.snapshot.json') -PathType Leaf)
                HumanReviewApproved      = $humanReviewExists
                BackupVerified           = $backupManifestExists
                ActivationPass           = (Test-Path -LiteralPath (Join-Path $EvidenceDir 'activation.json') -PathType Leaf)
                ValidateOnlyReadOnlyPass = -not [string]::IsNullOrWhiteSpace($validateOnly)
                SemanticParityZeroDiff   = [bool]$parity.Pass
                SelfTestPass             = (@($selfTestLog | Where-Object { $_ -match '\[FAIL\]' }).Count -eq 0)
                SelfTestNoUnavailable    = (@($selfTestLog | Where-Object { $_ -match '\[НЕДОСТУПНО\]' }).Count -eq 0)
                HealthPass               = (Test-Path -LiteralPath (Join-Path $EvidenceDir 'health.log') -PathType Leaf)
                ArchiveSmokePass         = (Test-Path -LiteralPath (Join-Path $EvidenceDir 'archive-smoke.log') -PathType Leaf)
                # NoSecretExposureDetected: SafeByConstruction, не post-hoc
                # сканування. Write-BRAVOPilotEvidenceJson/-Text викликають
                # Assert-BRAVOPilotEvidenceSecretSafe/-TextSecretSafe на
                # КОЖЕН запис доказу за весь час життєвого циклу
                # (Preflight/Prepare/Approve/Activate/Validate) і кидають
                # виняток, що зупиняє операцію, при виявленні секрето-
                # подібного рядка. Якщо виконання дійшло до -Accept з
                # повним пакетом доказів — жоден такий запис не міг
                # пройти неперевіреним. Повторне сканування тут дублювало
                # б ту саму канонічну реалізацію без додаткового доказу.
                NoSecretExposureDetected = $true
            }
            $acceptance = New-BRAVOPilotAcceptanceRecord -EvidenceDir $EvidenceDir -Criteria $criteria

            if ($acceptance.Result -eq 'PILOT ACCEPTED') {
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Accepted' | Out-Null
                Write-Host '[SUCCESS] PILOT ACCEPTED' -ForegroundColor Green
                exit 0
            } else {
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'Failed' | Out-Null
                Write-Host ("[FAILED] PILOT NOT ACCEPTED — критерії: {0}" -f ([string]::Join(', ', $acceptance.FailedCriteria))) -ForegroundColor Red
                exit 1
            }
        }

        'Rollback' {
            if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw "-InstallRoot є обов'язковим для -Rollback." }
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { throw "-EvidenceDir є обов'язковим для -Rollback." }
            $resolvedInstallRoot = Resolve-BRAVOPilotFullPath $InstallRoot

            $pilotLock = Enter-BRAVOPilotInstallRootLock -InstallRoot $resolvedInstallRoot
            try {
                $result = Invoke-BRAVOPilotRollback -InstallRoot $resolvedInstallRoot -EvidenceDir $EvidenceDir
                Set-BRAVOPilotState -EvidenceDir $EvidenceDir -State 'RolledBack' | Out-Null
                Write-Host "[SUCCESS] $($result.Result)" -ForegroundColor Green
                exit 0
            } finally {
                Exit-BRAVOPilotInstallRootLock -Mutex $pilotLock
            }
        }

        'Status' {
            if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
                Write-Host "Немає -EvidenceDir — показую лише параметри виклику."
                Write-Host "  InstallRoot:  $InstallRoot"
                Write-Host "  ArtifactRoot: $ArtifactRoot"
                Write-Host "  EvidenceRoot: $EvidenceRoot"
                exit 0
            }
            $state = Get-BRAVOPilotState -EvidenceDir $EvidenceDir
            if ($null -eq $state) {
                Write-Host "[INFO] У '$EvidenceDir' ще немає metadata.json (pilot не розпочато в цьому каталозі)."
                exit 0
            }
            Write-Host "State:        $($state.State)"
            Write-Host "UpdatedAtUtc: $($state.UpdatedAtUtc)"
            Write-Host "ServerId:     $($state.ServerId)"
            Write-Host "Operator:     $($state.Operator)"
            exit 0
        }
    }
} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 1
}
