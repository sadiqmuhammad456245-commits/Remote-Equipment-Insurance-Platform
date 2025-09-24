;; title: usage-pattern-tracker
;; version: 1.0.0
;; summary: Track equipment usage patterns and wear indicators
;; description: Smart contract for monitoring equipment usage patterns and calculating risk scores

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u404))
(define-constant ERR-INVALID-USAGE-DATA (err u400))
(define-constant ERR-EQUIPMENT-EXISTS (err u409))
(define-constant ERR-INVALID-TIME-PERIOD (err u422))

;; Usage pattern constants
(define-constant SECONDS-PER-DAY u86400)
(define-constant LIGHT-USAGE-THRESHOLD u4)  ;; 4 hours per day
(define-constant MODERATE-USAGE-THRESHOLD u8)  ;; 8 hours per day
(define-constant HEAVY-USAGE-THRESHOLD u12)  ;; 12 hours per day
(define-constant MAX-DAILY-USAGE u24)  ;; 24 hours per day
(define-constant WEAR-CALCULATION-PERIOD u30)  ;; 30 days for wear calculation

;; Risk score multipliers
(define-constant LIGHT-USAGE-MULTIPLIER u50)   ;; 0.5x risk
(define-constant MODERATE-USAGE-MULTIPLIER u100) ;; 1.0x risk
(define-constant HEAVY-USAGE-MULTIPLIER u150)   ;; 1.5x risk
(define-constant EXTREME-USAGE-MULTIPLIER u200) ;; 2.0x risk

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-tracked-equipment uint u0)

;; Equipment usage tracking data
(define-map equipment-usage
  { equipment-id: (string-ascii 64) }
  {
    owner: principal,
    equipment-type: (string-ascii 32),
    total-usage-hours: uint,
    daily-average-usage: uint,
    weekly-average-usage: uint,
    monthly-average-usage: uint,
    risk-score: uint,
    usage-category: (string-ascii 16),
    last-updated: uint,
    tracking-start-date: uint,
    performance-degradation: uint,
    predicted-maintenance-date: uint
  }
)

;; Daily usage records (rolling 30-day window)
(define-map daily-usage-records
  { equipment-id: (string-ascii 64), day-offset: uint }
  {
    date: uint,
    usage-hours: uint,
    active-sessions: uint,
    peak-performance: uint,
    average-performance: uint,
    wear-index: uint
  }
)

;; Usage sessions tracking
(define-map usage-sessions
  { equipment-id: (string-ascii 64), session-id: uint }
  {
    start-time: uint,
    end-time: uint,
    duration: uint,
    session-type: (string-ascii 32),
    performance-score: uint,
    wear-impact: uint
  }
)

;; Wear pattern analysis
(define-map wear-analysis
  { equipment-id: (string-ascii 64) }
  {
    current-wear-level: uint,
    wear-rate: uint,
    projected-lifespan: uint,
    maintenance-recommendations: (string-ascii 128),
    critical-wear-threshold: uint,
    last-analysis-date: uint
  }
)

;; Authorized data collectors (IoT devices, monitoring systems)
(define-map authorized-collectors principal bool)

;; Public functions

;; Register equipment for usage tracking
(define-public (register-equipment-tracking (equipment-id (string-ascii 64)) (equipment-type (string-ascii 32)))
  (let
    (
      (existing-equipment (map-get? equipment-usage { equipment-id: equipment-id }))
    )
    (asserts! (is-none existing-equipment) ERR-EQUIPMENT-EXISTS)
    (map-set equipment-usage
      { equipment-id: equipment-id }
      {
        owner: tx-sender,
        equipment-type: equipment-type,
        total-usage-hours: u0,
        daily-average-usage: u0,
        weekly-average-usage: u0,
        monthly-average-usage: u0,
        risk-score: u50,
        usage-category: "new",
        last-updated: burn-block-height,
        tracking-start-date: burn-block-height,
        performance-degradation: u0,
        predicted-maintenance-date: (+ burn-block-height u8760) ;; ~6 months in blocks
      }
    )
    (map-set wear-analysis
      { equipment-id: equipment-id }
      {
        current-wear-level: u0,
        wear-rate: u1,
        projected-lifespan: u26280, ;; ~18 months in blocks
        maintenance-recommendations: "Regular monitoring",
        critical-wear-threshold: u80,
        last-analysis-date: burn-block-height
      }
    )
    (var-set total-tracked-equipment (+ (var-get total-tracked-equipment) u1))
    (ok equipment-id)
  )
)

;; Record daily usage data
(define-public (record-daily-usage
  (equipment-id (string-ascii 64))
  (usage-hours uint)
  (active-sessions uint)
  (peak-performance uint)
  (average-performance uint)
)
  (let
    (
      (equipment-data (unwrap! (map-get? equipment-usage { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
      (current-day (mod burn-block-height WEAR-CALCULATION-PERIOD))
      (wear-index (calculate-wear-index usage-hours peak-performance average-performance))
    )
    (asserts! (default-to false (map-get? authorized-collectors tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (<= usage-hours MAX-DAILY-USAGE) ERR-INVALID-USAGE-DATA)
    (asserts! (and (>= peak-performance u0) (<= peak-performance u100)) ERR-INVALID-USAGE-DATA)
    (asserts! (and (>= average-performance u0) (<= average-performance u100)) ERR-INVALID-USAGE-DATA)
    
    ;; Record daily usage
    (map-set daily-usage-records
      { equipment-id: equipment-id, day-offset: current-day }
      {
        date: burn-block-height,
        usage-hours: usage-hours,
        active-sessions: active-sessions,
        peak-performance: peak-performance,
        average-performance: average-performance,
        wear-index: wear-index
      }
    )
    
    ;; Update equipment usage statistics
    (let
      (
        (new-total-hours (+ (get total-usage-hours equipment-data) usage-hours))
        (new-daily-avg (calculate-daily-average equipment-id))
        (new-risk-score (calculate-risk-score new-daily-avg))
        (new-category (determine-usage-category new-daily-avg))
        (degradation (calculate-performance-degradation equipment-id))
      )
      (map-set equipment-usage
        { equipment-id: equipment-id }
        (merge equipment-data {
          total-usage-hours: new-total-hours,
          daily-average-usage: new-daily-avg,
          weekly-average-usage: (* new-daily-avg u7),
          monthly-average-usage: (* new-daily-avg u30),
          risk-score: new-risk-score,
          usage-category: new-category,
          last-updated: burn-block-height,
          performance-degradation: degradation
        })
      )
    )
    
    (ok usage-hours)
  )
)

;; Record usage session
(define-public (record-usage-session
  (equipment-id (string-ascii 64))
  (session-id uint)
  (start-time uint)
  (duration uint)
  (session-type (string-ascii 32))
  (performance-score uint)
)
  (let
    (
      (equipment-data (unwrap! (map-get? equipment-usage { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
      (wear-impact (calculate-session-wear duration performance-score))
    )
    (asserts! (default-to false (map-get? authorized-collectors tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (> duration u0) ERR-INVALID-USAGE-DATA)
    (asserts! (and (>= performance-score u0) (<= performance-score u100)) ERR-INVALID-USAGE-DATA)
    
    (map-set usage-sessions
      { equipment-id: equipment-id, session-id: session-id }
      {
        start-time: start-time,
        end-time: (+ start-time duration),
        duration: duration,
        session-type: session-type,
        performance-score: performance-score,
        wear-impact: wear-impact
      }
    )
    
    (ok session-id)
  )
)

;; Update wear analysis
(define-public (update-wear-analysis (equipment-id (string-ascii 64)))
  (let
    (
      (equipment-data (unwrap! (map-get? equipment-usage { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
      (current-wear (unwrap! (map-get? wear-analysis { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner equipment-data)) ERR-NOT-AUTHORIZED)
    
    (let
      (
        (new-wear-level (calculate-current-wear-level equipment-id))
        (new-wear-rate (calculate-wear-rate equipment-id))
        (new-lifespan (calculate-projected-lifespan new-wear-level new-wear-rate))
        (recommendations (generate-maintenance-recommendations new-wear-level new-wear-rate))
      )
      (map-set wear-analysis
        { equipment-id: equipment-id }
        (merge current-wear {
          current-wear-level: new-wear-level,
          wear-rate: new-wear-rate,
          projected-lifespan: new-lifespan,
          maintenance-recommendations: recommendations,
          last-analysis-date: burn-block-height
        })
      )
    )
    
    (ok true)
  )
)

;; Authorize data collector
(define-public (authorize-collector (collector principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set authorized-collectors collector true)
    (ok true)
  )
)

;; Read-only functions

;; Get equipment usage data
(define-read-only (get-equipment-usage (equipment-id (string-ascii 64)))
  (map-get? equipment-usage { equipment-id: equipment-id })
)

;; Get daily usage record
(define-read-only (get-daily-usage (equipment-id (string-ascii 64)) (day-offset uint))
  (map-get? daily-usage-records { equipment-id: equipment-id, day-offset: day-offset })
)

;; Get usage session
(define-read-only (get-usage-session (equipment-id (string-ascii 64)) (session-id uint))
  (map-get? usage-sessions { equipment-id: equipment-id, session-id: session-id })
)

;; Get wear analysis
(define-read-only (get-wear-analysis (equipment-id (string-ascii 64)))
  (map-get? wear-analysis { equipment-id: equipment-id })
)

;; Calculate usage risk score for external use
(define-read-only (get-usage-risk-score (equipment-id (string-ascii 64)))
  (match (map-get? equipment-usage { equipment-id: equipment-id })
    equipment-data (ok (get risk-score equipment-data))
    ERR-EQUIPMENT-NOT-FOUND
  )
)

;; Get total tracked equipment count
(define-read-only (get-total-tracked-equipment)
  (var-get total-tracked-equipment)
)

;; Private functions

;; Calculate daily average usage over the tracking period
(define-private (calculate-daily-average (equipment-id (string-ascii 64)))
  (let
    (
      (total-days u0)
      (total-usage u0)
    )
    ;; Simple calculation - in real implementation would aggregate daily records
    u6 ;; Default 6 hours average
  )
)

;; Calculate risk score based on usage patterns
(define-private (calculate-risk-score (daily-average uint))
  (if (<= daily-average LIGHT-USAGE-THRESHOLD)
      LIGHT-USAGE-MULTIPLIER
      (if (<= daily-average MODERATE-USAGE-THRESHOLD)
          MODERATE-USAGE-MULTIPLIER
          (if (<= daily-average HEAVY-USAGE-THRESHOLD)
              HEAVY-USAGE-MULTIPLIER
              EXTREME-USAGE-MULTIPLIER
          )
      )
  )
)

;; Determine usage category
(define-private (determine-usage-category (daily-average uint))
  (if (<= daily-average LIGHT-USAGE-THRESHOLD)
      "light"
      (if (<= daily-average MODERATE-USAGE-THRESHOLD)
          "moderate"
          (if (<= daily-average HEAVY-USAGE-THRESHOLD)
              "heavy"
              "extreme"
          )
      )
  )
)

;; Calculate wear index for daily usage
(define-private (calculate-wear-index (usage-hours uint) (peak-perf uint) (avg-perf uint))
  (let
    (
      (base-wear (/ usage-hours u2))
      (performance-factor (if (< avg-perf u50) u2 u1))
    )
    (* base-wear performance-factor)
  )
)

;; Calculate session wear impact
(define-private (calculate-session-wear (duration uint) (performance uint))
  (let
    (
      (base-wear (/ duration u3600)) ;; Convert to hours
      (perf-multiplier (if (< performance u70) u150 u100))
    )
    (/ (* base-wear perf-multiplier) u100)
  )
)

;; Calculate current wear level
(define-private (calculate-current-wear-level (equipment-id (string-ascii 64)))
  ;; Simplified calculation - in real implementation would analyze wear patterns
  u25
)

;; Calculate wear rate
(define-private (calculate-wear-rate (equipment-id (string-ascii 64)))
  ;; Simplified calculation
  u2
)

;; Calculate projected lifespan
(define-private (calculate-projected-lifespan (wear-level uint) (wear-rate uint))
  (if (> wear-rate u0)
      (/ (* (- u100 wear-level) u365) wear-rate) ;; Days remaining
      u36500 ;; ~100 years if no wear detected
  )
)

;; Calculate performance degradation
(define-private (calculate-performance-degradation (equipment-id (string-ascii 64)))
  ;; Simplified calculation
  u5
)

;; Generate maintenance recommendations
(define-private (generate-maintenance-recommendations (wear-level uint) (wear-rate uint))
  (if (> wear-level u60)
      "Schedule maintenance soon"
      (if (> wear-level u30)
          "Monitor closely"
          "Normal operation"
      )
  )
)
