;; node-pulse
;; 
;; This smart contract implements the NodePulse monitoring system for Stacks blockchain nodes.
;; It provides functionality to register nodes, submit health reports, validate node status,
;; and calculate reputation scores based on performance metrics. The contract serves as a
;; transparent registry that helps stakeholders identify reliable nodes in the ecosystem.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NODE-NOT-FOUND (err u101))
(define-constant ERR-NODE-ALREADY-REGISTERED (err u102))
(define-constant ERR-INVALID-REPORT-FREQUENCY (err u103))
(define-constant ERR-REPORT-TOO-SOON (err u104))
(define-constant ERR-INVALID-UPTIME (err u105))
(define-constant ERR-INVALID-RESPONSE-TIME (err u106))
(define-constant ERR-VALIDATOR-ALREADY-SUBMITTED (err u107))
(define-constant ERR-NOT-VALIDATOR (err u108))
(define-constant ERR-INVALID-VALIDATION (err u109))

;; Consensus constants
(define-constant MINIMUM_REPORT_INTERVAL u3600) ;; Minimum 1 hour between reports
(define-constant MAX_UPTIME u100) ;; Maximum uptime percentage
(define-constant MIN_RESPONSE_TIME u0) ;; Minimum response time in ms
(define-constant MAX_RESPONSE_TIME u10000) ;; Maximum response time 10 seconds
(define-constant REPUTATION_BASE u1000) ;; Base value for reputation calculations
(define-constant REPUTATION_DECAY_RATE u950) ;; 95% retention per week (applied to existing reputation)
(define-constant UPTIME_WEIGHT u3) ;; Weight of uptime in reputation calculation
(define-constant RESPONSE_TIME_WEIGHT u2) ;; Weight of response time in reputation calculation
(define-constant VALIDATOR_THRESHOLD u3) ;; Number of validations needed to consider a report confirmed

;; Data structures

;; Node information
(define-map nodes
  { node-id: (string-ascii 50) } ;; Unique identifier for the node
  {
    owner: principal, ;; Owner of the node
    name: (string-utf8 100), ;; Readable name
    url: (string-ascii 100), ;; URL endpoint for the node
    location: (string-ascii 50), ;; Geographic location
    features: (list 20 (string-ascii 50)), ;; List of supported features
    registration-time: uint, ;; When the node was registered
    reputation-score: uint, ;; Current reputation score
    latest-report-time: uint ;; Timestamp of most recent health report
  }
)

;; Health reports
(define-map health-reports
  { 
    node-id: (string-ascii 50),
    report-time: uint
  }
  {
    uptime: uint, ;; Percentage uptime since last report (0-100)
    response-time: uint, ;; Average response time in milliseconds
    block-height: uint, ;; Current block height on the node
    validations: uint, ;; Number of independent validations
    is-confirmed: bool ;; Whether report has been sufficiently validated
  }
)

;; Track which validators validated which reports
(define-map report-validations
  {
    node-id: (string-ascii 50),
    report-time: uint,
    validator: principal
  }
  {
    is-valid: bool, ;; Validator's assessment of report accuracy
    validation-time: uint ;; When validation was submitted
  }
)

;; Track all registered validators
(define-map validators
  { validator: principal }
  { is-active: bool }
)

;; Node IDs for efficient iteration
(define-data-var next-node-index uint u0)
(define-map node-index-to-id
  { index: uint }
  { node-id: (string-ascii 50) }
)

;; Private functions

;; Calculate reputation score based on uptime and response time
;; Uptime should be as high as possible (100% is ideal)
;; Response time should be as low as possible (0ms is ideal)
(define-private (calculate-reputation (uptime uint) (response-time uint))
  (let
    (
      ;; Normalize response time to a 0-100 scale (inverted, so lower is better)
      (normalized-response-time (if (> response-time MAX-RESPONSE-TIME)
                                  u0
                                  (- u100 (/ (* response-time u100) MAX-RESPONSE-TIME))))
      
      ;; Calculate weighted score components
      (uptime-score (* uptime UPTIME_WEIGHT))
      (response-time-score (* normalized-response-time RESPONSE_TIME_WEIGHT))
      
      ;; Combine scores with appropriate weighting
      (total-score (/ (+ uptime-score response-time-score) (+ UPTIME_WEIGHT RESPONSE_TIME_WEIGHT)))
    )
    ;; Return the final score
    total-score
  )
)

;; Update a node's reputation based on latest health report
(define-private (update-node-reputation (node-id (string-ascii 50)) (uptime uint) (response-time uint))
  (let
    (
      (node-data (unwrap! (map-get? nodes { node-id: node-id }) (tuple)))
      (current-reputation (get reputation-score node-data))
      (new-reputation-component (calculate-reputation uptime response-time))
      
      ;; Apply decay to existing reputation and add new component
      (updated-reputation (+ (/ (* current-reputation REPUTATION_DECAY_RATE) u1000) 
                           (/ (* new-reputation-component (- u1000 REPUTATION_DECAY_RATE)) u1000)))
    )
    (map-set nodes
      { node-id: node-id }
      (merge node-data { 
        reputation-score: updated-reputation,
        latest-report-time: block-height 
      })
    )
    updated-reputation
  )
)

;; Validate inputs for health report
(define-private (validate-health-report (uptime uint) (response-time uint))
  (begin
    (asserts! (<= uptime MAX_UPTIME) ERR-INVALID-UPTIME)
    (asserts! (>= response-time MIN_RESPONSE_TIME) ERR-INVALID-RESPONSE-TIME)
    (ok true)
  )
)

;; Check if tx-sender is the node owner
(define-private (is-node-owner (node-id (string-ascii 50)))
  (let ((node-data (unwrap! (map-get? nodes { node-id: node-id }) false)))
    (is-eq tx-sender (get owner node-data))
  )
)

;; Read-only functions

;; Get node information
(define-read-only (get-node-info (node-id (string-ascii 50)))
  (map-get? nodes { node-id: node-id })
)

;; Get the latest health report for a node
(define-read-only (get-latest-health-report (node-id (string-ascii 50)))
  (let
    ((node-data (unwrap! (map-get? nodes { node-id: node-id }) none)))
    (map-get? health-reports { 
      node-id: node-id,
      report-time: (get latest-report-time node-data)
    })
  )
)

;; Get a specific health report by time
(define-read-only (get-health-report (node-id (string-ascii 50)) (report-time uint))
  (map-get? health-reports { node-id: node-id, report-time: report-time })
)

;; Check if a validator has submitted validation for a specific report
(define-read-only (has-validator-submitted (node-id (string-ascii 50)) (report-time uint) (validator principal))
  (is-some (map-get? report-validations 
    { node-id: node-id, report-time: report-time, validator: validator }))
)

;; Get the total number of registered nodes
(define-read-only (get-node-count)
  (var-get next-node-index)
)

;; Get node ID by index (for iterating through all nodes)
(define-read-only (get-node-id-by-index (index uint))
  (map-get? node-index-to-id { index: index })
)

;; Check if principal is a registered validator
(define-read-only (is-validator (principal principal))
  (default-to false 
    (get is-active (map-get? validators { validator: principal })))
)

;; Public functions

;; Register a new node
(define-public (register-node 
  (node-id (string-ascii 50))
  (name (string-utf8 100))
  (url (string-ascii 100))
  (location (string-ascii 50))
  (features (list 20 (string-ascii 50))))
  
  (let
    ((node-index (var-get next-node-index)))
    
    ;; Check node doesn't already exist
    (asserts! (is-none (map-get? nodes { node-id: node-id })) 
              ERR-NODE-ALREADY-REGISTERED)
    
    ;; Register the node
    (map-set nodes
      { node-id: node-id }
      {
        owner: tx-sender,
        name: name,
        url: url,
        location: location,
        features: features,
        registration-time: block-height,
        reputation-score: REPUTATION_BASE,
        latest-report-time: u0
      }
    )
    
    ;; Add to the node index for enumeration
    (map-set node-index-to-id
      { index: node-index }
      { node-id: node-id }
    )
    
    ;; Increment the node index counter
    (var-set next-node-index (+ node-index u1))
    
    (ok node-id)
  )
)

;; Submit a health report for a node
(define-public (submit-health-report 
  (node-id (string-ascii 50))
  (uptime uint)
  (response-time uint)
  (block-height-reported uint))
  
  (let
    ((node-data (unwrap! (map-get? nodes { node-id: node-id }) ERR-NODE-NOT-FOUND))
     (current-time block-height)
     (last-report-time (get latest-report-time node-data)))
    
    ;; Ensure sender is the node owner
    (asserts! (is-eq tx-sender (get owner node-data)) ERR-NOT-AUTHORIZED)
    
    ;; Validate report values
    (try! (validate-health-report uptime response-time))
    
    ;; Ensure reports aren't too frequent
    (asserts! (or 
      (is-eq last-report-time u0) 
      (>= (- current-time last-report-time) MINIMUM_REPORT_INTERVAL)) 
      ERR-REPORT-TOO-SOON)
    
    ;; Store the health report
    (map-set health-reports
      { node-id: node-id, report-time: current-time }
      {
        uptime: uptime,
        response-time: response-time,
        block-height: block-height-reported,
        validations: u0,
        is-confirmed: false
      }
    )
    
    ;; Update the node's latest report time
    (map-set nodes
      { node-id: node-id }
      (merge node-data { latest-report-time: current-time })
    )
    
    ;; Update reputation score
    (update-node-reputation node-id uptime response-time)
    
    (ok true)
  )
)

;; Register as a validator
(define-public (register-validator)
  (begin
    (map-set validators
      { validator: tx-sender }
      { is-active: true }
    )
    (ok true)
  )
)

;; Deactivate validator status
(define-public (deactivate-validator)
  (begin
    (map-set validators
      { validator: tx-sender }
      { is-active: false }
    )
    (ok true)
  )
)

;; Submit validation for a health report
(define-public (validate-health-report
  (node-id (string-ascii 50))
  (report-time uint)
  (is-valid bool))
  
  (let
    ((report (unwrap! (map-get? health-reports 
                        { node-id: node-id, report-time: report-time }) 
                      ERR-NODE-NOT-FOUND))
     (current-validations (get validations report)))
    
    ;; Ensure sender is a registered validator
    (asserts! (is-validator tx-sender) ERR-NOT-VALIDATOR)
    
    ;; Ensure validator hasn't already submitted for this report
    (asserts! (is-none (map-get? report-validations 
      { node-id: node-id, report-time: report-time, validator: tx-sender }))
      ERR-VALIDATOR-ALREADY-SUBMITTED)
    
    ;; Record validation
    (map-set report-validations
      { node-id: node-id, report-time: report-time, validator: tx-sender }
      { is-valid: is-valid, validation-time: block-height }
    )
    
    ;; Update validation count in health report
    (let
      ((new-validation-count (+ current-validations u1))
       (confirmed (>= new-validation-count VALIDATOR_THRESHOLD)))
      
      (map-set health-reports
        { node-id: node-id, report-time: report-time }
        (merge report {
          validations: new-validation-count,
          is-confirmed: confirmed
        })
      )
      
      (ok true)
    )
  )
)

;; Update node information (only owner can update)
(define-public (update-node-info
  (node-id (string-ascii 50))
  (name (string-utf8 100))
  (url (string-ascii 100))
  (location (string-ascii 50))
  (features (list 20 (string-ascii 50))))
  
  (let
    ((node-data (unwrap! (map-get? nodes { node-id: node-id }) ERR-NODE-NOT-FOUND)))
    
    ;; Ensure sender is the node owner
    (asserts! (is-eq tx-sender (get owner node-data)) ERR-NOT-AUTHORIZED)
    
    ;; Update the node information
    (map-set nodes
      { node-id: node-id }
      (merge node-data {
        name: name,
        url: url,
        location: location,
        features: features
      })
    )
    
    (ok true)
  )
)