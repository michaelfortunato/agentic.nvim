--- @class agentic.session.SubmissionQueue
--- @field _items agentic.SessionManager.QueuedSubmission[]
--- @field _next_id integer
--- @field _interrupt_submission? agentic.SessionManager.QueuedSubmission
local SubmissionQueue = {}
SubmissionQueue.__index = SubmissionQueue

--- @return agentic.session.SubmissionQueue
function SubmissionQueue:new()
    return setmetatable({
        _items = {},
        _next_id = 0,
        _interrupt_submission = nil,
    }, self)
end

--- @return integer
function SubmissionQueue:count()
    return #self._items
end

--- @return boolean
function SubmissionQueue:is_empty()
    return #self._items == 0
end

--- @return agentic.SessionManager.QueuedSubmission[]
function SubmissionQueue:list()
    return self._items
end

--- @return agentic.SessionManager.QueuedSubmission|nil
function SubmissionQueue:get_interrupt_submission()
    return self._interrupt_submission
end

--- @param submission agentic.SessionManager.QueuedSubmission
--- @return integer
function SubmissionQueue:enqueue(submission)
    self._next_id = self._next_id + 1
    submission.id = self._next_id
    self._items[#self._items + 1] = submission
    return submission.id
end

--- @param submission_id integer
--- @return integer|nil
function SubmissionQueue:find_index(submission_id)
    for index, submission in ipairs(self._items) do
        if submission.id == submission_id then
            return index
        end
    end

    return nil
end

--- @param submission_id integer
--- @return agentic.SessionManager.QueuedSubmission|nil
function SubmissionQueue:remove(submission_id)
    if
        self._interrupt_submission
        and self._interrupt_submission.id == submission_id
    then
        local interrupt_submission = self._interrupt_submission
        self._interrupt_submission = nil
        return interrupt_submission
    end

    local submission_index = self:find_index(submission_id)
    if not submission_index then
        return nil
    end

    return table.remove(self._items, submission_index)
end

--- @param submission_id integer
--- @return agentic.SessionManager.QueuedSubmission|nil
function SubmissionQueue:prioritize(submission_id)
    local submission = self:remove(submission_id)
    if not submission then
        return nil
    end

    table.insert(self._items, 1, submission)
    return submission
end

--- @param submission_id integer
--- @return agentic.SessionManager.QueuedSubmission|nil
function SubmissionQueue:interrupt_with(submission_id)
    local submission = self:remove(submission_id)
    if not submission then
        return nil
    end

    self._interrupt_submission = submission
    return submission
end

--- @return agentic.SessionManager.QueuedSubmission|nil
function SubmissionQueue:pop_next()
    local next_submission = self._interrupt_submission
    self._interrupt_submission = nil

    if next_submission then
        return next_submission
    end

    if #self._items == 0 then
        return nil
    end

    return table.remove(self._items, 1)
end

--- @return boolean
function SubmissionQueue:clear()
    local had_items = self._interrupt_submission ~= nil or #self._items > 0
    self._items = {}
    self._interrupt_submission = nil
    return had_items
end

return SubmissionQueue
