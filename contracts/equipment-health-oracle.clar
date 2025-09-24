;; title: equipment-health-oracle
;; version: 1.0.0
;; summary: Monitor remote work equipment performance and health status
;; description: Smart contract for tracking equipment health metrics through IoT sensors

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u404))
(define-constant ERR-INVALID-HEALTH-SCORE (err u400))
(define-constant ERR-EQUIPMENT-EXISTS (err u409))
(define-constant ERR-INVALID-SENSOR-DATA (err u422))

;; Health thresholds
(define-constant MIN-HEALTH-SCORE u0)
(define-constant MAX-HEALTH-SCORE u100)
(define-constant CRITICAL-HEALTH-THRESHOLD u20)
(define-constant WARNING-HEALTH-THRESHOLD u50)
(define-constant OPTIMAL-HEALTH-THRESHOLD u80)

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-equipment-count uint u0)

;; Equipment health data structure
(define-map equipment-health
  { equipment-id: (string-ascii 64) }
  {
    owner: principal,
    equipment-type: (string-ascii 32),
    health-score: uint,
    temperature: uint,
    humidity: uint,
    performance-score: uint,
    last-updated: uint,
    status: (string-ascii 16),
    sensor-readings-count: uint,
    maintenance-alerts: uint
  }
)

;; Equipment sensor readings history (limited to last 10 readings)
(define-map sensor-readings-history
  { equipment-id: (string-ascii 64), reading-index: uint }
  {
    timestamp: uint,
    temperature: uint,
    humidity: uint,
    performance: uint,
    health-score: uint
  }
)

;; Equipment maintenance history
(define-map maintenance-history
  { equipment-id: (string-ascii 64), maintenance-id: uint }
  {
    timestamp: uint,
    maintenance-type: (string-ascii 32),
    description: (string-ascii 128),
    resolved: bool
  }
)

;; Authorized oracles for updating equipment data
(define-map authorized-oracles principal bool)

;; Public functions

;; Register new equipment for monitoring
(define-public (register-equipment (equipment-id (string-ascii 64)) (equipment-type (string-ascii 32)))
  (let
    (
      (existing-equipment (map-get? equipment-health { equipment-id: equipment-id }))
    )
    (asserts! (is-none existing-equipment) ERR-EQUIPMENT-EXISTS)
    (map-set equipment-health
      { equipment-id: equipment-id }
      {
        owner: tx-sender,
        equipment-type: equipment-type,
        health-score: u100,
        temperature: u22,
        humidity: u45,
        performance-score: u100,
        last-updated: burn-block-height,
        status: "healthy",
        sensor-readings-count: u0,
        maintenance-alerts: u0
      }
    )
    (var-set total-equipment-count (+ (var-get total-equipment-count) u1))
    (ok equipment-id)
  )
)

;; Update equipment health data (oracle only)
(define-public (update-equipment-health 
  (equipment-id (string-ascii 64))
  (temperature uint)
  (humidity uint)
  (performance uint)
)
  (let
    (
      (equipment-data (unwrap! (map-get? equipment-health { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
      (calculated-health (calculate-health-score temperature humidity performance))
      (new-status (determine-status calculated-health))
      (reading-index (get sensor-readings-count equipment-data))
    )
    (asserts! (default-to false (map-get? authorized-oracles tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= temperature u0) (<= temperature u100)) ERR-INVALID-SENSOR-DATA)
    (asserts! (and (>= humidity u0) (<= humidity u100)) ERR-INVALID-SENSOR-DATA)
    (asserts! (and (>= performance u0) (<= performance u100)) ERR-INVALID-SENSOR-DATA)
    
    ;; Update equipment health data
    (map-set equipment-health
      { equipment-id: equipment-id }
      (merge equipment-data {
        health-score: calculated-health,
        temperature: temperature,
        humidity: humidity,
        performance-score: performance,
        last-updated: burn-block-height,
        status: new-status,
        sensor-readings-count: (+ reading-index u1),
        maintenance-alerts: (if (<= calculated-health CRITICAL-HEALTH-THRESHOLD) 
                               (+ (get maintenance-alerts equipment-data) u1) 
                               (get maintenance-alerts equipment-data))
      })
    )
    
    ;; Store sensor reading in history (keep only last 10 readings)
    (map-set sensor-readings-history
      { equipment-id: equipment-id, reading-index: (mod reading-index u10) }
      {
        timestamp: burn-block-height,
        temperature: temperature,
        humidity: humidity,
        performance: performance,
        health-score: calculated-health
      }
    )
    
    (ok calculated-health)
  )
)

;; Add maintenance record
(define-public (add-maintenance-record
  (equipment-id (string-ascii 64))
  (maintenance-id uint)
  (maintenance-type (string-ascii 32))
  (description (string-ascii 128))
)
  (let
    (
      (equipment-data (unwrap! (map-get? equipment-health { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner equipment-data)) ERR-NOT-AUTHORIZED)
    (map-set maintenance-history
      { equipment-id: equipment-id, maintenance-id: maintenance-id }
      {
        timestamp: burn-block-height,
        maintenance-type: maintenance-type,
        description: description,
        resolved: false
      }
    )
    (ok maintenance-id)
  )
)

;; Authorize oracle
(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set authorized-oracles oracle true)
    (ok true)
  )
)

;; Remove oracle authorization
(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-delete authorized-oracles oracle)
    (ok true)
  )
)

;; Read-only functions

;; Get equipment health data
(define-read-only (get-equipment-health (equipment-id (string-ascii 64)))
  (map-get? equipment-health { equipment-id: equipment-id })
)

;; Get sensor reading history
(define-read-only (get-sensor-reading (equipment-id (string-ascii 64)) (reading-index uint))
  (map-get? sensor-readings-history { equipment-id: equipment-id, reading-index: reading-index })
)

;; Get maintenance record
(define-read-only (get-maintenance-record (equipment-id (string-ascii 64)) (maintenance-id uint))
  (map-get? maintenance-history { equipment-id: equipment-id, maintenance-id: maintenance-id })
)

;; Check if oracle is authorized
(define-read-only (is-authorized-oracle (oracle principal))
  (default-to false (map-get? authorized-oracles oracle))
)

;; Get total equipment count
(define-read-only (get-total-equipment-count)
  (var-get total-equipment-count)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Private functions

;; Calculate health score based on sensor data
(define-private (calculate-health-score (temperature uint) (humidity uint) (performance uint))
  (let
    (
      (temp-score (if (and (>= temperature u18) (<= temperature u28)) u100
                     (if (and (>= temperature u15) (<= temperature u35)) u80
                        (if (and (>= temperature u10) (<= temperature u40)) u60 u20))))
      (humidity-score (if (and (>= humidity u30) (<= humidity u60)) u100
                         (if (and (>= humidity u20) (<= humidity u70)) u80
                            (if (and (>= humidity u10) (<= humidity u80)) u60 u20))))
      (overall-score (/ (+ temp-score humidity-score performance) u3))
    )
    (if (> overall-score MAX-HEALTH-SCORE) MAX-HEALTH-SCORE overall-score)
  )
)

;; Determine equipment status based on health score
(define-private (determine-status (health-score uint))
  (if (<= health-score CRITICAL-HEALTH-THRESHOLD)
      "critical"
      (if (<= health-score WARNING-HEALTH-THRESHOLD)
          "warning"
          (if (>= health-score OPTIMAL-HEALTH-THRESHOLD)
              "optimal"
              "healthy"
          )
      )
  )
)
