-- Open sales orders, newest first
-- Acme storefront orders that still wait for fulfillment.
SELECT t.id, t.tranid, t.trandate, BUILTIN.DF(t.entity) AS customer, t.foreigntotal
FROM transaction t
WHERE t.type = 'SalesOrd'
  AND t.status = 'SalesOrd:B'
ORDER BY t.trandate DESC
