local assert = require("tests.helpers.assert")

describe("agentic.utils.PermissionOption", function()
    local PermissionOption

    before_each(function()
        PermissionOption = require("agentic.utils.permission_option")
    end)

    it("normalizes permission kinds from option ids and names", function()
        assert.equal(
            "allow_once",
            PermissionOption.get_kind({
                optionId = "allow-once",
                name = "Allow once",
            })
        )
        assert.equal(
            "reject_always",
            PermissionOption.get_kind({
                optionId = "reject-always",
                name = "Reject always",
            })
        )
    end)

    it("finds option ids without requiring explicit kind fields", function()
        local options = {
            { optionId = "allow-once", name = "Allow once" },
            { optionId = "allow-always", name = "Allow always" },
            { optionId = "reject-once", name = "Reject once" },
            { optionId = "reject-always", name = "Reject always" },
        }

        assert.equal(
            "allow-once",
            PermissionOption.find_option_id(options, { "allow_once" })
        )
        assert.equal(
            "allow-always",
            PermissionOption.find_option_id(options, { "allow_always" })
        )
        assert.equal(
            "reject-once",
            PermissionOption.find_option_id(options, { "reject_once" })
        )
        assert.equal(
            "reject-always",
            PermissionOption.find_option_id(options, { "reject_always" })
        )
    end)

    it("maps selected option ids back to approval state", function()
        assert.equal(
            "approved",
            PermissionOption.get_state_for_option_id(
                { { optionId = "allow-once", name = "Allow once" } },
                "allow-once"
            )
        )
        assert.equal(
            "rejected",
            PermissionOption.get_state_for_option_id(
                { { optionId = "reject-always", name = "Reject always" } },
                "reject-always"
            )
        )
        assert.equal(
            "dismissed",
            PermissionOption.get_state_for_option_id({}, nil)
        )
    end)
end)
