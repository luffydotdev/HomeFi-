;; Property Token Contract
;; Handles fractional ownership and issuance of property tokens as NFTs

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_ALREADY_EXISTS (err u102))
(define-constant ERR_INVALID_PARAMS (err u103))
(define-constant ERR_TRANSFER_FAILED (err u104))

;; Data Variables
(define-data-var next-token-id uint u1)
(define-data-var contract-uri (string-ascii 256) "")

;; Define the NFT
(define-non-fungible-token property-token uint)

;; Property Information Structure
(define-map property-info
  uint ;; token-id
  {
    metadata-uri: (string-ascii 256),
    legal-docs-hash: (buff 32),
    valuation: uint,
    property-address: (string-ascii 512),
    total-shares: uint,
    shares-per-token: uint,
    created-at: uint,
    status: (string-ascii 32) ;; "active", "delisted", "sold"
  }
)

;; Admin/DAO Management
(define-map authorized-minters principal bool)

;; Fractional Ownership Tracking
(define-map token-shares
  uint ;; token-id
  {
    total-supply: uint,
    available-shares: uint
  }
)

;; Share ownership per user per property
(define-map user-property-shares
  {user: principal, token-id: uint}
  uint ;; number of shares owned
)

;; Events
(define-map property-events
  {token-id: uint, event-type: (string-ascii 32)}
  {
    timestamp: uint,
    details: (string-ascii 512)
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-authorized-minter)
  (default-to false (map-get? authorized-minters tx-sender))
)

(define-private (can-mint)
  (or (is-contract-owner) (is-authorized-minter))
)

;; Admin Functions
(define-public (add-authorized-minter (minter principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (ok (map-set authorized-minters minter true))
  )
)

(define-public (remove-authorized-minter (minter principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (ok (map-delete authorized-minters minter))
  )
)

(define-public (set-contract-uri (uri (string-ascii 256)))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (ok (var-set contract-uri uri))
  )
)

;; Core NFT Functions
(define-public (mint-property-token 
    (recipient principal)
    (metadata-uri (string-ascii 256))
    (legal-docs-hash (buff 32))
    (valuation uint)
    (property-address (string-ascii 512))
    (total-shares uint)
    (shares-per-token uint))
  (let 
    (
      (token-id (var-get next-token-id))
    )
    (begin
      ;; Check authorization
      (asserts! (can-mint) ERR_UNAUTHORIZED)
      
      ;; Validate parameters
      (asserts! (> valuation u0) ERR_INVALID_PARAMS)
      (asserts! (> total-shares u0) ERR_INVALID_PARAMS)
      (asserts! (> shares-per-token u0) ERR_INVALID_PARAMS)
      (asserts! (<= shares-per-token total-shares) ERR_INVALID_PARAMS)
      
      ;; Mint the NFT
      (try! (nft-mint? property-token token-id recipient))
      
      ;; Store property information
      (map-set property-info token-id {
        metadata-uri: metadata-uri,
        legal-docs-hash: legal-docs-hash,
        valuation: valuation,
        property-address: property-address,
        total-shares: total-shares,
        shares-per-token: shares-per-token,
        created-at: stacks-block-height,
        status: "active"
      })
      
      ;; Initialize share tracking
      (map-set token-shares token-id {
        total-supply: total-shares,
        available-shares: total-shares
      })
      
      ;; Set initial share ownership
      (map-set user-property-shares 
        {user: recipient, token-id: token-id} 
        shares-per-token)
      
      ;; Log creation event
      (map-set property-events 
        {token-id: token-id, event-type: "created"}
        {
          timestamp: stacks-block-height,
          details: "Property token created and minted"
        })
      
      ;; Increment token ID for next mint
      (var-set next-token-id (+ token-id u1))
      
      (ok token-id)
    )
  )
)

(define-public (transfer-property-token (token-id uint) (sender principal) (recipient principal))
  (let
    (
      (current-owner (unwrap! (nft-get-owner? property-token token-id) ERR_NOT_FOUND))
      (property-data (unwrap! (map-get? property-info token-id) ERR_NOT_FOUND))
      (sender-shares (default-to u0 (map-get? user-property-shares {user: sender, token-id: token-id})))
    )
    (begin
      ;; Verify sender is current owner or authorized
      (asserts! (or (is-eq tx-sender current-owner) (is-eq tx-sender sender)) ERR_UNAUTHORIZED)
      (asserts! (is-eq current-owner sender) ERR_UNAUTHORIZED)
      
      ;; Check property is active
      (asserts! (is-eq (get status property-data) "active") ERR_TRANSFER_FAILED)
      
      ;; Transfer the NFT
      (try! (nft-transfer? property-token token-id sender recipient))
      
      ;; Transfer shares
      (if (> sender-shares u0)
        (begin
          (map-delete user-property-shares {user: sender, token-id: token-id})
          (map-set user-property-shares 
            {user: recipient, token-id: token-id} 
            sender-shares)
        )
        true
      )
      
      ;; Log transfer event
      (map-set property-events 
        {token-id: token-id, event-type: "transferred"}
        {
          timestamp: stacks-block-height,
          details: "Property token ownership transferred"
        })
      
      (ok true)
    )
  )
)

(define-public (burn-property-token (token-id uint))
  (let
    (
      (current-owner (unwrap! (nft-get-owner? property-token token-id) ERR_NOT_FOUND))
      (property-data (unwrap! (map-get? property-info token-id) ERR_NOT_FOUND))
    )
    (begin
      ;; Check authorization (owner or admin)
      (asserts! (or (is-eq tx-sender current-owner) (can-mint)) ERR_UNAUTHORIZED)
      
      ;; Burn the NFT
      (try! (nft-burn? property-token token-id current-owner))
      
      ;; Update property status
      (map-set property-info token-id 
        (merge property-data {status: "burned"}))
      
      ;; Clean up share ownership
      (map-delete user-property-shares {user: current-owner, token-id: token-id})
      
      ;; Log burn event
      (map-set property-events 
        {token-id: token-id, event-type: "burned"}
        {
          timestamp: stacks-block-height,
          details: "Property token burned - delisted or sold"
        })
      
      (ok true)
    )
  )
)

;; Read-only Functions
(define-read-only (get-property-info (token-id uint))
  (map-get? property-info token-id)
)

(define-read-only (get-token-owner (token-id uint))
  (nft-get-owner? property-token token-id)
)

(define-read-only (get-user-shares (user principal) (token-id uint))
  (default-to u0 (map-get? user-property-shares {user: user, token-id: token-id}))
)

(define-read-only (get-token-shares-info (token-id uint))
  (map-get? token-shares token-id)
)

(define-read-only (get-property-event (token-id uint) (event-type (string-ascii 32)))
  (map-get? property-events {token-id: token-id, event-type: event-type})
)

(define-read-only (get-next-token-id)
  (var-get next-token-id)
)

(define-read-only (get-contract-uri)
  (var-get contract-uri)
)

(define-read-only (is-authorized-minter-check (user principal))
  (default-to false (map-get? authorized-minters user))
)

;; Property Management Functions
(define-public (update-property-valuation (token-id uint) (new-valuation uint))
  (let
    (
      (property-data (unwrap! (map-get? property-info token-id) ERR_NOT_FOUND))
      (current-owner (unwrap! (nft-get-owner? property-token token-id) ERR_NOT_FOUND))
    )
    (begin
      ;; Check authorization
      (asserts! (or (is-eq tx-sender current-owner) (can-mint)) ERR_UNAUTHORIZED)
      (asserts! (> new-valuation u0) ERR_INVALID_PARAMS)
      
      ;; Update valuation
      (map-set property-info token-id 
        (merge property-data {valuation: new-valuation}))
      
      ;; Log valuation update
      (map-set property-events 
        {token-id: token-id, event-type: "valuation-updated"}
        {
          timestamp: stacks-block-height,
          details: "Property valuation updated"
        })
      
      (ok true)
    )
  )
)

(define-public (update-property-status (token-id uint) (new-status (string-ascii 32)))
  (let
    (
      (property-data (unwrap! (map-get? property-info token-id) ERR_NOT_FOUND))
    )
    (begin
      ;; Check authorization (only admin/DAO can change status)
      (asserts! (can-mint) ERR_UNAUTHORIZED)
      
      ;; Update status
      (map-set property-info token-id 
        (merge property-data {status: new-status}))
      
      ;; Log status update
      (map-set property-events 
        {token-id: token-id, event-type: "status-updated"}
        {
          timestamp: stacks-block-height,
          details: new-status
        })
      
      (ok true)
    )
  )
)

;; Utility Functions
(define-read-only (get-total-supply)
  (- (var-get next-token-id) u1)
)

(define-read-only (token-exists (token-id uint))
  (is-some (map-get? property-info token-id))
)