;; Conversion Tracking Contract
;; Handles end-to-end conversion attribution and revenue tracking

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u500))
(define-constant ERR_CONVERSION_NOT_FOUND (err u501))
(define-constant ERR_INVALID_ATTRIBUTION (err u502))
(define-constant ERR_DUPLICATE_CONVERSION (err u503))
(define-constant ERR_NOT_FOUND (err u504))

;; Attribution models
(define-constant ATTRIBUTION_FIRST_TOUCH u1)
(define-constant ATTRIBUTION_LAST_TOUCH u2)
(define-constant ATTRIBUTION_LINEAR u3)
(define-constant ATTRIBUTION_TIME_DECAY u4)
(define-constant ATTRIBUTION_POSITION_BASED u5)

;; Conversion types
(define-constant CONVERSION_LEAD u1)
(define-constant CONVERSION_OPPORTUNITY u2)
(define-constant CONVERSION_CUSTOMER u3)
(define-constant CONVERSION_REVENUE u4)

;; Conversion events
(define-map conversions
  { conversion-id: uint }
  {
    lead-id: uint,
    conversion-type: uint,
    value: uint,
    timestamp: uint,
    attribution-model: uint,
    campaign-id: uint,
    manager: principal,
    verified: bool
  }
)

;; Touch point tracking
(define-map touchpoints
  { lead-id: uint, touchpoint-id: uint }
  {
    channel: (string-ascii 50),
    campaign-id: uint,
    timestamp: uint,
    value-contribution: uint,
    attribution-weight: uint
  }
)

;; Attribution results
(define-map attribution-results
  { conversion-id: uint }
  {
    total-touchpoints: uint,
    primary-channel: (string-ascii 50),
    primary-campaign: uint,
    attribution-breakdown: (list 10 { channel: (string-ascii 50), weight: uint, value: uint })
  }
)

;; Revenue tracking
(define-map revenue-tracking
  { period: uint, campaign-id: uint }
  {
    total-revenue: uint,
    total-conversions: uint,
    average-deal-size: uint,
    cost-per-acquisition: uint,
    return-on-investment: uint
  }
)

;; Campaign performance
(define-map campaign-performance
  { campaign-id: uint }
  {
    total-leads: uint,
    qualified-leads: uint,
    opportunities: uint,
    customers: uint,
    total-revenue: uint,
    conversion-rate: uint,
    average-sales-cycle: uint
  }
)

;; Funnel analytics
(define-map funnel-analytics
  { funnel-id: uint }
  {
    stage-1-count: uint,  ;; Leads
    stage-2-count: uint,  ;; Qualified
    stage-3-count: uint,  ;; Opportunities
    stage-4-count: uint,  ;; Customers
    stage-1-to-2-rate: uint,
    stage-2-to-3-rate: uint,
    stage-3-to-4-rate: uint,
    overall-conversion-rate: uint
  }
)

;; Counters
(define-data-var conversion-counter uint u0)
(define-data-var touchpoint-counter uint u0)

;; Record conversion
(define-public (record-conversion
  (lead-id uint)
  (conversion-type uint)
  (value uint)
  (attribution-model uint)
  (campaign-id uint))
  (let (
    (conversion-id (+ (var-get conversion-counter) u1))
  )
    (asserts! (is-valid-conversion-type conversion-type) ERR_INVALID_ATTRIBUTION)
    (asserts! (is-valid-attribution-model attribution-model) ERR_INVALID_ATTRIBUTION)

    ;; Check for duplicate conversions
    (asserts! (not (has-conversion lead-id conversion-type)) ERR_DUPLICATE_CONVERSION)

    (map-set conversions
      { conversion-id: conversion-id }
      {
        lead-id: lead-id,
        conversion-type: conversion-type,
        value: value,
        timestamp: block-height,
        attribution-model: attribution-model,
        campaign-id: campaign-id,
        manager: tx-sender,
        verified: false
      }
    )

    ;; Calculate attribution
    (unwrap! (calculate-attribution conversion-id) (err u505))

    ;; Update campaign performance
    (update-campaign-performance campaign-id conversion-type value)

    ;; Update funnel analytics
    (update-funnel-analytics campaign-id conversion-type)

    (var-set conversion-counter conversion-id)
    (ok conversion-id)
  )
)

;; Add touchpoint
(define-public (add-touchpoint
  (lead-id uint)
  (channel (string-ascii 50))
  (campaign-id uint))
  (let (
    (touchpoint-id (+ (var-get touchpoint-counter) u1))
  )
    (map-set touchpoints
      { lead-id: lead-id, touchpoint-id: touchpoint-id }
      {
        channel: channel,
        campaign-id: campaign-id,
        timestamp: block-height,
        value-contribution: u0,
        attribution-weight: u0
      }
    )

    (var-set touchpoint-counter touchpoint-id)
    (ok touchpoint-id)
  )
)

;; Verify conversion
(define-public (verify-conversion (conversion-id uint))
  (let (
    (conversion-data (unwrap! (map-get? conversions { conversion-id: conversion-id }) ERR_CONVERSION_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set conversions
      { conversion-id: conversion-id }
      (merge conversion-data { verified: true })
    )

    (ok true)
  )
)

;; Calculate multi-touch attribution
(define-public (calculate-attribution (conversion-id uint))
  (let (
    (conversion-data (unwrap! (map-get? conversions { conversion-id: conversion-id }) ERR_CONVERSION_NOT_FOUND))
    (lead-id (get lead-id conversion-data))
    (attribution-model (get attribution-model conversion-data))
    (conversion-value (get value conversion-data))
  )
    ;; Get all touchpoints for this lead
    (let (
      (touchpoint-count (count-lead-touchpoints lead-id))
    )
      (if (> touchpoint-count u0)
        (begin
          ;; Apply attribution model
          (apply-attribution-model lead-id attribution-model conversion-value)

          ;; Store attribution results
          (map-set attribution-results
            { conversion-id: conversion-id }
            {
              total-touchpoints: touchpoint-count,
              primary-channel: (get-primary-channel lead-id),
              primary-campaign: (get campaign-id conversion-data),
              attribution-breakdown: (get-attribution-breakdown lead-id)
            }
          )

          (ok true))
        (ok false))
    )
  )
)

;; Update revenue tracking
(define-public (update-revenue-tracking
  (period uint)
  (campaign-id uint)
  (revenue uint)
  (cost uint))
  (let (
    (current-data (default-to
      { total-revenue: u0, total-conversions: u0, average-deal-size: u0, cost-per-acquisition: u0, return-on-investment: u0 }
      (map-get? revenue-tracking { period: period, campaign-id: campaign-id })))
    (new-conversions (+ (get total-conversions current-data) u1))
    (new-revenue (+ (get total-revenue current-data) revenue))
    (new-avg-deal (if (> new-conversions u0) (/ new-revenue new-conversions) u0))
    (new-cpa (if (> new-conversions u0) (/ cost new-conversions) u0))
    (new-roi (if (> cost u0) (/ (* (- new-revenue cost) u100) cost) u0))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set revenue-tracking
      { period: period, campaign-id: campaign-id }
      {
        total-revenue: new-revenue,
        total-conversions: new-conversions,
        average-deal-size: new-avg-deal,
        cost-per-acquisition: new-cpa,
        return-on-investment: new-roi
      }
    )

    (ok true)
  )
)

;; Helper functions
(define-private (is-valid-conversion-type (conversion-type uint))
  (or (is-eq conversion-type CONVERSION_LEAD)
      (or (is-eq conversion-type CONVERSION_OPPORTUNITY)
          (or (is-eq conversion-type CONVERSION_CUSTOMER)
              (is-eq conversion-type CONVERSION_REVENUE))))
)

(define-private (is-valid-attribution-model (model uint))
  (or (is-eq model ATTRIBUTION_FIRST_TOUCH)
      (or (is-eq model ATTRIBUTION_LAST_TOUCH)
          (or (is-eq model ATTRIBUTION_LINEAR)
              (or (is-eq model ATTRIBUTION_TIME_DECAY)
                  (is-eq model ATTRIBUTION_POSITION_BASED)))))
)

(define-private (has-conversion (lead-id uint) (conversion-type uint))
  ;; Simple check - in production would iterate through conversions
  false
)

(define-private (count-lead-touchpoints (lead-id uint))
  ;; Simplified - would count actual touchpoints
  u3
)

(define-private (get-primary-channel (lead-id uint))
  ;; Simplified - would analyze touchpoints
  "email"
)

(define-private (get-attribution-breakdown (lead-id uint))
  ;; Simplified attribution breakdown
  (list
    { channel: "email", weight: u40, value: u400 }
    { channel: "social", weight: u30, value: u300 }
    { channel: "direct", weight: u30, value: u300 })
)

(define-private (apply-attribution-model (lead-id uint) (model uint) (value uint))
  ;; Attribution logic would be implemented here
  true
)

(define-private (update-campaign-conversion (campaign-id uint) (conversion-type uint) (value uint))
  (match (map-get? campaign-performance { campaign-id: campaign-id })
    current-perf
    (begin
      (map-set campaign-performance
        { campaign-id: campaign-id }
        (if (is-eq conversion-type CONVERSION_CUSTOMER)
          (merge current-perf {
            customers: (+ (get customers current-perf) u1),
            total-revenue: (+ (get total-revenue current-perf) value)
          })
          (if (is-eq conversion-type CONVERSION_OPPORTUNITY)
            (merge current-perf { opportunities: (+ (get opportunities current-perf) u1) })
            current-perf)))
      true)
    false)
)

(define-private (update-campaign-performance (campaign-id uint) (conversion-type uint) (value uint))
  (let (
    (current-perf (default-to
      { total-leads: u0, qualified-leads: u0, opportunities: u0, customers: u0, total-revenue: u0, conversion-rate: u0, average-sales-cycle: u0 }
      (map-get? campaign-performance { campaign-id: campaign-id })))
  )
    (map-set campaign-performance
      { campaign-id: campaign-id }
      (if (is-eq conversion-type CONVERSION_CUSTOMER)
        (merge current-perf {
          customers: (+ (get customers current-perf) u1),
          total-revenue: (+ (get total-revenue current-perf) value)
        })
        (if (is-eq conversion-type CONVERSION_OPPORTUNITY)
          (merge current-perf { opportunities: (+ (get opportunities current-perf) u1) })
          current-perf)))
  )
)

(define-private (update-funnel-analytics (campaign-id uint) (conversion-type uint))
  ;; Funnel analytics update logic
  true
)

;; Read-only functions
(define-read-only (get-conversion-info (conversion-id uint))
  (map-get? conversions { conversion-id: conversion-id })
)

(define-read-only (get-touchpoint-info (lead-id uint) (touchpoint-id uint))
  (map-get? touchpoints { lead-id: lead-id, touchpoint-id: touchpoint-id })
)

(define-read-only (get-attribution-results (conversion-id uint))
  (map-get? attribution-results { conversion-id: conversion-id })
)

(define-read-only (get-revenue-tracking (period uint) (campaign-id uint))
  (map-get? revenue-tracking { period: period, campaign-id: campaign-id })
)

(define-read-only (get-campaign-performance (campaign-id uint))
  (map-get? campaign-performance { campaign-id: campaign-id })
)

(define-read-only (get-conversion-rate (campaign-id uint))
  (match (map-get? campaign-performance { campaign-id: campaign-id })
    perf-data
      (if (> (get total-leads perf-data) u0)
        (some (/ (* (get customers perf-data) u100) (get total-leads perf-data)))
        (some u0))
    none
  )
)

(define-read-only (get-roi (period uint) (campaign-id uint))
  (match (map-get? revenue-tracking { period: period, campaign-id: campaign-id })
    revenue-data (some (get return-on-investment revenue-data))
    none
  )
)
