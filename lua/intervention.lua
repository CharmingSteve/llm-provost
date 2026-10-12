-- Single source for the governance rejection brand. Rule engines return bare
-- reasons; the HTTP boundary applies this prefix exactly once.
local _M = {}

_M.PREFIX = "PROVOST_INTERVENTION: "

function _M.brand(reason)
    reason = tostring(reason or "Policy violation")
    if reason:sub(1, #_M.PREFIX) == _M.PREFIX then
        return reason
    end
    return _M.PREFIX .. reason
end

return _M
