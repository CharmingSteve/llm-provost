local test_environment = setmetatable({
	assert = assert,
	describe = describe,
	it = it,
}, {__index = _G})

for _, path in ipairs({
	"tests/test_audit_contract.lua",
	"tests/test_identity_extraction.lua",
}) do
	local chunk
	if setfenv then
		chunk = assert(loadfile(path))
		setfenv(chunk, test_environment)
	else
		chunk = assert(loadfile(path, "t", test_environment))
	end
	chunk()
end