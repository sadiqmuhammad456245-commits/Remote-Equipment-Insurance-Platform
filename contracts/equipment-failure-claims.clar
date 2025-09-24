;; title: equipment-failure-claims
;; version: 1.0.0
;; summary: Instant payouts for remote work equipment failures affecting productivity
;; description: Smart contract for automated insurance claim processing and payouts

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-CLAIM-NOT-FOUND (err u404))
(define-constant ERR-INVALID-CLAIM-DATA (err u400))
(define-constant ERR-CLAIM-ALREADY-PROCESSED (err u409))
(define-constant ERR-INSUFFICIENT-FUNDS (err u402))
(define-constant ERR-POLICY-NOT-ACTIVE (err u403))
(define-constant ERR-EQUIPMENT-NOT-INSURED (err u404))
(define-constant ERR-CLAIM-PERIOD-EXPIRED (err u410))

;; Claim status constants
(define-constant STATUS-PENDING "pending")
(define-constant STATUS-APPROVED "approved")
(define-constant STATUS-REJECTED "rejected")
(define-constant STATUS-PAID "paid")
(define-constant STATUS-DISPUTED "disputed")

;; Failure type constants
(define-constant FAILURE-HARDWARE "hardware")
(define-constant FAILURE-PERFORMANCE "performance")
(define-constant FAILURE-ENVIRONMENTAL "environmental")
(define-constant FAILURE-WEAR "wear")

;; Payout calculation constants
(define-constant BASE-PAYOUT-AMOUNT u1000000) ;; 1 STX in microSTX
(define-constant MIN-PAYOUT-AMOUNT u100000)   ;; 0.1 STX
(define-constant MAX-PAYOUT-AMOUNT u10000000) ;; 10 STX
(define-constant CLAIM-PROCESSING-FEE u50000) ;; 0.05 STX
(define-constant CLAIM-VALIDITY_PERIOD u1440) ;; ~10 days in blocks

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-claims-count uint u0)
(define-data-var total-payouts-amount uint u0)
(define-data-var contract-balance uint u0)

;; Insurance policies for equipment
(define-map insurance-policies
  { equipment-id: (string-ascii 64) }
  {
    policy-holder: principal,
    equipment-type: (string-ascii 32),
    coverage-amount: uint,
    premium-paid: uint,
    policy-start-date: uint,
    policy-end-date: uint,
    is-active: bool,
    claim-count: uint,
    last-claim-date: uint,
    risk-multiplier: uint
  }
)

;; Claims data structure
(define-map insurance-claims
  { claim-id: uint }
  {
    claimant: principal,
    equipment-id: (string-ascii 64),
    claim-amount: uint,
    failure-type: (string-ascii 16),
    failure-description: (string-ascii 256),
    claim-date: uint,
    status: (string-ascii 16),
    evidence-hash: (buff 32),
    health-score-at-failure: uint,
    usage-hours-at-failure: uint,
    payout-amount: uint,
    processing-date: uint,
    auto-approved: bool
  }
)

;; Evidence submissions for claims
(define-map claim-evidence
  { claim-id: uint, evidence-id: uint }
  {
    evidence-type: (string-ascii 32),
    evidence-hash: (buff 32),
    submission-date: uint,
    verified: bool,
    verification-date: uint
  }
)

;; Premium payments tracking
(define-map premium-payments
  { equipment-id: (string-ascii 64), payment-id: uint }
  {
    payer: principal,
    amount: uint,
    payment-date: uint,
    coverage-period: uint,
    payment-hash: (buff 32)
  }
)

;; Authorized claim processors
(define-map authorized-processors principal bool)

;; Claim ID counter
(define-data-var next-claim-id uint u1)

;; Public functions

;; Create insurance policy for equipment
(define-public (create-insurance-policy
  (equipment-id (string-ascii 64))
  (equipment-type (string-ascii 32))
  (coverage-amount uint)
  (premium-amount uint)
  (coverage-duration uint)
)
  (let
    (
      (existing-policy (map-get? insurance-policies { equipment-id: equipment-id }))
    )
    (asserts! (is-none existing-policy) ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (> coverage-amount u0) ERR-INVALID-CLAIM-DATA)
    (asserts! (> premium-amount u0) ERR-INVALID-CLAIM-DATA)
    
    (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
    
    (map-set insurance-policies
      { equipment-id: equipment-id }
      {
        policy-holder: tx-sender,
        equipment-type: equipment-type,
        coverage-amount: coverage-amount,
        premium-paid: premium-amount,
        policy-start-date: burn-block-height,
        policy-end-date: (+ burn-block-height coverage-duration),
        is-active: true,
        claim-count: u0,
        last-claim-date: u0,
        risk-multiplier: u100
      }
    )
    
    (var-set contract-balance (+ (var-get contract-balance) premium-amount))
    (ok equipment-id)
  )
)

;; Submit insurance claim
(define-public (submit-claim
  (equipment-id (string-ascii 64))
  (claim-amount uint)
  (failure-type (string-ascii 16))
  (failure-description (string-ascii 256))
  (evidence-hash (buff 32))
  (health-score uint)
  (usage-hours uint)
)
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-INSURED))
      (claim-id (var-get next-claim-id))
    )
    (asserts! (get is-active policy) ERR-POLICY-NOT-ACTIVE)
    (asserts! (<= burn-block-height (get policy-end-date policy)) ERR-CLAIM-PERIOD-EXPIRED)
    (asserts! (is-eq tx-sender (get policy-holder policy)) ERR-NOT-AUTHORIZED)
    (asserts! (<= claim-amount (get coverage-amount policy)) ERR-INVALID-CLAIM-DATA)
    
    (map-set insurance-claims
      { claim-id: claim-id }
      {
        claimant: tx-sender,
        equipment-id: equipment-id,
        claim-amount: claim-amount,
        failure-type: failure-type,
        failure-description: failure-description,
        claim-date: burn-block-height,
        status: STATUS-PENDING,
        evidence-hash: evidence-hash,
        health-score-at-failure: health-score,
        usage-hours-at-failure: usage-hours,
        payout-amount: u0,
        processing-date: u0,
        auto-approved: false
      }
    )
    
    ;; Auto-approve claims that meet certain criteria
    (if (evaluate-auto-approval claim-id health-score failure-type)
        (unwrap-panic (process-automatic-payout claim-id))
        u0
    )
    
    (var-set next-claim-id (+ claim-id u1))
    (var-set total-claims-count (+ (var-get total-claims-count) u1))
    (ok claim-id)
  )
)

;; Process claim (authorized processors only)
(define-public (process-claim (claim-id uint) (approved bool) (payout-amount uint))
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
    )
    (asserts! (default-to false (map-get? authorized-processors tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) STATUS-PENDING) ERR-CLAIM-ALREADY-PROCESSED)
    
    (if approved
        (begin
          (asserts! (<= payout-amount (get claim-amount claim)) ERR-INVALID-CLAIM-DATA)
          (asserts! (>= (var-get contract-balance) payout-amount) ERR-INSUFFICIENT-FUNDS)
          
          ;; Transfer payout to claimant
          (try! (as-contract (stx-transfer? payout-amount tx-sender (get claimant claim))))
          
          ;; Update claim status
          (map-set insurance-claims
            { claim-id: claim-id }
            (merge claim {
              status: STATUS-PAID,
              payout-amount: payout-amount,
              processing-date: burn-block-height
            })
          )
          
          ;; Update contract balance and totals
          (var-set contract-balance (- (var-get contract-balance) payout-amount))
          (var-set total-payouts-amount (+ (var-get total-payouts-amount) payout-amount))
          
          ;; Update policy claim count
          (match (map-get? insurance-policies { equipment-id: (get equipment-id claim) })
            policy-data
            (begin
              (map-set insurance-policies
                { equipment-id: (get equipment-id claim) }
                (merge policy-data {
                  claim-count: (+ (get claim-count policy-data) u1),
                  last-claim-date: burn-block-height
                })
              )
              true
            )
            false
          )
          
          (ok payout-amount)
        )
        (begin
          ;; Reject claim
          (map-set insurance-claims
            { claim-id: claim-id }
            (merge claim {
              status: STATUS-REJECTED,
              processing-date: burn-block-height
            })
          )
          (ok u0)
        )
    )
  )
)

;; Add evidence to claim
(define-public (add-claim-evidence
  (claim-id uint)
  (evidence-id uint)
  (evidence-type (string-ascii 32))
  (evidence-hash (buff 32))
)
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get claimant claim)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) STATUS-PENDING) ERR-CLAIM-ALREADY-PROCESSED)
    
    (map-set claim-evidence
      { claim-id: claim-id, evidence-id: evidence-id }
      {
        evidence-type: evidence-type,
        evidence-hash: evidence-hash,
        submission-date: burn-block-height,
        verified: false,
        verification-date: u0
      }
    )
    
    (ok evidence-id)
  )
)

;; Renew insurance policy
(define-public (renew-policy
  (equipment-id (string-ascii 64))
  (premium-amount uint)
  (coverage-duration uint)
)
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-INSURED))
    )
    (asserts! (is-eq tx-sender (get policy-holder policy)) ERR-NOT-AUTHORIZED)
    (asserts! (> premium-amount u0) ERR-INVALID-CLAIM-DATA)
    
    (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
    
    (map-set insurance-policies
      { equipment-id: equipment-id }
      (merge policy {
        premium-paid: (+ (get premium-paid policy) premium-amount),
        policy-end-date: (+ (get policy-end-date policy) coverage-duration),
        is-active: true
      })
    )
    
    (var-set contract-balance (+ (var-get contract-balance) premium-amount))
    (ok true)
  )
)

;; Authorize claim processor
(define-public (authorize-processor (processor principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set authorized-processors processor true)
    (ok true)
  )
)

;; Read-only functions

;; Get insurance policy
(define-read-only (get-insurance-policy (equipment-id (string-ascii 64)))
  (map-get? insurance-policies { equipment-id: equipment-id })
)

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

;; Get claim evidence
(define-read-only (get-claim-evidence (claim-id uint) (evidence-id uint))
  (map-get? claim-evidence { claim-id: claim-id, evidence-id: evidence-id })
)

;; Check if policy is active
(define-read-only (is-policy-active (equipment-id (string-ascii 64)))
  (match (map-get? insurance-policies { equipment-id: equipment-id })
    policy (and (get is-active policy) (<= burn-block-height (get policy-end-date policy)))
    false
  )
)

;; Calculate premium for equipment
(define-read-only (calculate-premium
  (equipment-type (string-ascii 32))
  (coverage-amount uint)
  (risk-score uint)
)
  (let
    (
      (base-rate (get-base-rate equipment-type))
      (risk-multiplier (/ risk-score u100))
      (coverage-factor (/ coverage-amount u1000000))
    )
    (* (* base-rate risk-multiplier) coverage-factor)
  )
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-claims: (var-get total-claims-count),
    total-payouts: (var-get total-payouts-amount),
    contract-balance: (var-get contract-balance),
    next-claim-id: (var-get next-claim-id)
  }
)

;; Private functions

;; Process automatic payout for qualifying claims
(define-private (process-automatic-payout (claim-id uint))
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
      (calculated-payout (calculate-payout-amount claim-id))
    )
    (asserts! (>= (var-get contract-balance) calculated-payout) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer automatic payout
    (try! (as-contract (stx-transfer? calculated-payout tx-sender (get claimant claim))))
    
    ;; Update claim with automatic approval
    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        status: STATUS-PAID,
        payout-amount: calculated-payout,
        processing-date: burn-block-height,
        auto-approved: true
      })
    )
    
    ;; Update balances
    (var-set contract-balance (- (var-get contract-balance) calculated-payout))
    (var-set total-payouts-amount (+ (var-get total-payouts-amount) calculated-payout))
    
    (ok calculated-payout)
  )
)

;; Evaluate if claim qualifies for automatic approval
(define-private (evaluate-auto-approval (claim-id uint) (health-score uint) (failure-type (string-ascii 16)))
  (and
    (<= health-score u20)  ;; Critical health score
    (or
      (is-eq failure-type FAILURE-HARDWARE)
      (is-eq failure-type FAILURE-PERFORMANCE)
    )
  )
)

;; Calculate payout amount based on claim parameters
(define-private (calculate-payout-amount (claim-id uint))
  (match (map-get? insurance-claims { claim-id: claim-id })
    claim
    (let
      (
        (base-amount (get claim-amount claim))
        (health-factor (if (<= (get health-score-at-failure claim) u10) u120 u100))
        (calculated-amount (/ (* base-amount health-factor) u100))
      )
      (if (> calculated-amount MAX-PAYOUT-AMOUNT)
          MAX-PAYOUT-AMOUNT
          (if (< calculated-amount MIN-PAYOUT-AMOUNT)
              MIN-PAYOUT-AMOUNT
              calculated-amount
          )
      )
    )
    MIN-PAYOUT-AMOUNT
  )
)

;; Get base insurance rate by equipment type
(define-private (get-base-rate (equipment-type (string-ascii 32)))
  (if (is-eq equipment-type "laptop")
      u200000  ;; 0.2 STX base rate
      (if (is-eq equipment-type "desktop")
          u150000  ;; 0.15 STX base rate
          (if (is-eq equipment-type "monitor")
              u100000  ;; 0.1 STX base rate
              u120000  ;; 0.12 STX default rate
          )
      )
  )
)
