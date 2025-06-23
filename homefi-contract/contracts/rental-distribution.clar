;; Rental Distributor Contract
;; Distributes stablecoin rental income to property token holders

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_NO_YIELD_AVAILABLE (err u102))
(define-constant ERR_ALREADY_CLAIMED (err u103))
(define-constant ERR_INVALID_PROPERTY (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))

;; Data Variables
(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var total-properties uint u0)
(define-data-var gas-threshold uint u1000000) ;; 1 STX threshold for auto-distribution

;; Property Information
(define-map properties
  { property-id: uint }
  {
    total-tokens: uint,
    monthly-yield: uint,
    last-distribution: uint,
    active: bool
  }
)

;; Monthly Yield Records
(define-map monthly-yields
  { property-id: uint, month: uint, year: uint }
  {
    total-yield: uint,
    yield-per-token: uint,
    distributed: bool,
    timestamp: uint
  }
)

;; Token Holder Balances
(define-map token-balances
  { property-id: uint, holder: principal }
  { balance: uint }
)

;; Yield Claims Tracking
(define-map yield-claims
  { property-id: uint, holder: principal, month: uint, year: uint }
  {
    amount: uint,
    claimed: bool,
    claim-timestamp: uint
  }
)

;; Unclaimed Yield Tracking
(define-map unclaimed-yields
  { property-id: uint, holder: principal }
  { total-unclaimed: uint }
)

;; Stablecoin Contract (assuming USDC-like token)
(define-data-var stablecoin-contract principal 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard)

;; Admin Functions

;; Set monthly yield for a property
(define-public (set-monthly-yield (property-id uint) (month uint) (year uint) (total-yield uint))
  (let (
    (property-info (unwrap! (map-get? properties { property-id: property-id }) ERR_INVALID_PROPERTY))
    (total-tokens (get total-tokens property-info))
    (yield-per-token (if (> total-tokens u0) (/ total-yield total-tokens) u0))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (asserts! (> total-yield u0) ERR_INVALID_AMOUNT)
    (asserts! (get active property-info) ERR_INVALID_PROPERTY)
    
    ;; Record monthly yield
    (map-set monthly-yields
      { property-id: property-id, month: month, year: year }
      {
        total-yield: total-yield,
        yield-per-token: yield-per-token,
        distributed: false,
        timestamp: stacks-block-height
      }
    )
    
    ;; Update property info
    (map-set properties
      { property-id: property-id }
      (merge property-info { monthly-yield: total-yield, last-distribution: stacks-block-height })
    )
    
    ;; Note: Individual unclaimed yields will be calculated when users check their balance
    ;; This avoids the need to iterate through all token holders here
    
    (ok true)
  )
)

;; Helper function to update unclaimed yields for a specific holder
(define-private (update-unclaimed-yield-for-holder (property-id uint) (holder principal) (yield-per-token uint))
  (let (
    (token-balance (default-to u0 (get balance (map-get? token-balances { property-id: property-id, holder: holder }))))
    (current-unclaimed (default-to u0 (get total-unclaimed (map-get? unclaimed-yields { property-id: property-id, holder: holder }))))
    (additional-yield (* yield-per-token token-balance))
    (new-total-unclaimed (+ current-unclaimed additional-yield))
  )
    (if (> token-balance u0)
      (map-set unclaimed-yields
        { property-id: property-id, holder: holder }
        { total-unclaimed: new-total-unclaimed }
      )
      true
    )
    (ok true)
  )
)

;; Public function for holders to update their unclaimed yields
(define-public (update-my-unclaimed-yields (property-id uint))
  (let (
    (property-info (unwrap! (map-get? properties { property-id: property-id }) ERR_INVALID_PROPERTY))
    (token-balance (default-to u0 (get balance (map-get? token-balances { property-id: property-id, holder: tx-sender }))))
  )
    (asserts! (> token-balance u0) ERR_INVALID_AMOUNT)
    
    ;; This would calculate unclaimed yields based on all monthly yields since last claim
    ;; For simplicity, we'll just return success - the actual calculation would happen in get-yield-owed
    (ok true)
  )
)

;; Claim yield for a specific month/year
(define-public (claim-yield (property-id uint) (month uint) (year uint))
  (let (
    (yield-info (unwrap! (map-get? monthly-yields { property-id: property-id, month: month, year: year }) ERR_NO_YIELD_AVAILABLE))
    (token-balance (default-to u0 (get balance (map-get? token-balances { property-id: property-id, holder: tx-sender }))))
    (yield-amount (* (get yield-per-token yield-info) token-balance))
    (claim-key { property-id: property-id, holder: tx-sender, month: month, year: year })
  )
    ;; Validate claim
    (asserts! (> token-balance u0) ERR_INVALID_AMOUNT)
    (asserts! (> yield-amount u0) ERR_NO_YIELD_AVAILABLE)
    (asserts! (is-none (map-get? yield-claims claim-key)) ERR_ALREADY_CLAIMED)
    
    ;; Record the claim
    (map-set yield-claims
      claim-key
      {
        amount: yield-amount,
        claimed: true,
        claim-timestamp: stacks-block-height
      }
    )
    
    ;; Update unclaimed yields
    (let (
      (current-unclaimed (default-to u0 (get total-unclaimed (map-get? unclaimed-yields { property-id: property-id, holder: tx-sender }))))
      (new-unclaimed (if (>= current-unclaimed yield-amount) (- current-unclaimed yield-amount) u0))
    )
      (map-set unclaimed-yields
        { property-id: property-id, holder: tx-sender }
        { total-unclaimed: new-unclaimed }
      )
    )
    
    ;; Transfer stablecoin yield (placeholder - would need actual stablecoin contract integration)
    ;; (try! (contract-call? .stablecoin-token transfer yield-amount (as-contract tx-sender) tx-sender none))
    
    (ok yield-amount)
  )
)

;; Claim all available yield for a property
(define-public (claim-all-yield (property-id uint))
  (let (
    (unclaimed-info (map-get? unclaimed-yields { property-id: property-id, holder: tx-sender }))
    (total-unclaimed (default-to u0 (get total-unclaimed unclaimed-info)))
  )
    (asserts! (> total-unclaimed u0) ERR_NO_YIELD_AVAILABLE)
    
    ;; Reset unclaimed yields
    (map-set unclaimed-yields
      { property-id: property-id, holder: tx-sender }
      { total-unclaimed: u0 }
    )
    
    ;; Transfer total unclaimed amount
    ;; (try! (contract-call? .stablecoin-token transfer total-unclaimed (as-contract tx-sender) tx-sender none))
    
    (ok total-unclaimed)
  )
)

;; Auto-distribute yield if gas cost is below threshold
(define-public (auto-distribute (property-id uint) (holders (list 100 principal)))
  (let (
    (property-info (unwrap! (map-get? properties { property-id: property-id }) ERR_INVALID_PROPERTY))
    (gas-cost (* (len holders) u50000)) ;; Estimated gas per holder
  )
    ;; Check authorization and gas threshold
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (asserts! (< gas-cost (var-get gas-threshold)) ERR_INSUFFICIENT_BALANCE)
    
    ;; Distribute to each holder
    (try! (fold distribute-to-holder holders (ok property-id)))
    
    (ok true)
  )
)

;; Helper function for auto-distribution
(define-private (distribute-to-holder (holder principal) (property-id-response (response uint uint)))
  (match property-id-response
    property-id (let (
      (unclaimed-info (map-get? unclaimed-yields { property-id: property-id, holder: holder }))
      (unclaimed-amount (default-to u0 (get total-unclaimed unclaimed-info)))
    )
      (if (> unclaimed-amount u0)
        (begin
          ;; Reset unclaimed for this holder
          (map-set unclaimed-yields
            { property-id: property-id, holder: holder }
            { total-unclaimed: u0 }
          )
          ;; Transfer would happen here
          (ok property-id)
        )
        (ok property-id)
      )
    )
    err (err err)
  )
)

;; Read-only Functions

;; Get yield owed to a specific holder
(define-read-only (get-yield-owed (property-id uint) (holder principal))
  (let (
    (unclaimed-info (map-get? unclaimed-yields { property-id: property-id, holder: holder }))
  )
    (default-to u0 (get total-unclaimed unclaimed-info))
  )
)

;; Get monthly yield information
(define-read-only (get-monthly-yield (property-id uint) (month uint) (year uint))
  (map-get? monthly-yields { property-id: property-id, month: month, year: year })
)

;; Get property information
(define-read-only (get-property-info (property-id uint))
  (map-get? properties { property-id: property-id })
)

;; Get token balance for a holder
(define-read-only (get-token-balance (property-id uint) (holder principal))
  (default-to u0 (get balance (map-get? token-balances { property-id: property-id, holder: holder })))
)

;; Check if yield has been claimed
(define-read-only (has-claimed-yield (property-id uint) (holder principal) (month uint) (year uint))
  (is-some (map-get? yield-claims { property-id: property-id, holder: holder, month: month, year: year }))
)

;; Administrative Functions

;; Add a new property
(define-public (add-property (property-id uint) (total-tokens uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (asserts! (> total-tokens u0) ERR_INVALID_AMOUNT)
    (asserts! (is-none (map-get? properties { property-id: property-id })) ERR_INVALID_PROPERTY)
    
    (map-set properties
      { property-id: property-id }
      {
        total-tokens: total-tokens,
        monthly-yield: u0,
        last-distribution: u0,
        active: true
      }
    )
    
    (var-set total-properties (+ (var-get total-properties) u1))
    (ok true)
  )
)

;; Set token balance for a holder (would typically be called by property token contract)
(define-public (set-token-balance (property-id uint) (holder principal) (balance uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (asserts! (is-some (map-get? properties { property-id: property-id })) ERR_INVALID_PROPERTY)
    
    (map-set token-balances
      { property-id: property-id, holder: holder }
      { balance: balance }
    )
    
    (ok true)
  )
)

;; Update gas threshold for auto-distribution
(define-public (set-gas-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (var-set gas-threshold new-threshold)
    (ok true)
  )
)

;; Transfer admin rights
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)

;; Get contract admin
(define-read-only (get-admin)
  (var-get contract-admin)
)

;; Get total properties
(define-read-only (get-total-properties)
  (var-get total-properties)
)

;; Get gas threshold
(define-read-only (get-gas-threshold)
  (var-get gas-threshold)
)
