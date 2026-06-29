import Foundation
import SQLite3

extension CascadeStore {
    @discardableResult
    public func upsertAgentTrace(_ row: AgentTraceRow) throws -> AgentTraceRow {
        let safe = AgentTraceRow(
            traceID: row.traceID,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            surface: Self.sanitizeStoredText(row.surface) ?? row.surface,
            actor: Self.sanitizeStoredText(row.actor) ?? row.actor,
            title: Self.sanitizeStoredText(row.title) ?? row.title,
            goalHash: Self.sanitizeStoredText(row.goalHash),
            appName: Self.sanitizeStoredText(row.appName),
            bundleIdentifier: Self.sanitizeStoredText(row.bundleIdentifier),
            status: row.status,
            failureKind: Self.sanitizeStoredText(row.failureKind),
            rootAuditEventID: row.rootAuditEventID,
            totalInputTokens: row.totalInputTokens,
            totalCacheReadTokens: row.totalCacheReadTokens,
            totalCacheCreationTokens: row.totalCacheCreationTokens,
            totalOutputTokens: row.totalOutputTokens,
            totalReasoningTokens: row.totalReasoningTokens,
            totalCostMicrousd: row.totalCostMicrousd,
            redactionPolicy: Self.sanitizeStoredText(row.redactionPolicy) ?? row.redactionPolicy,
            metadataJSON: Self.sanitizeStoredText(row.metadataJSON)
        )
        let sql = """
        INSERT INTO agent_trace
            (trace_id, started_at, ended_at, surface, actor, title, goal_hash, app_name, bundle_identifier, status,
             failure_kind, root_audit_event_id, total_input_tokens, total_cache_read_tokens, total_cache_creation_tokens,
             total_output_tokens, total_reasoning_tokens, total_cost_microusd, redaction_policy, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(trace_id) DO UPDATE SET
            started_at = excluded.started_at,
            ended_at = excluded.ended_at,
            surface = excluded.surface,
            actor = excluded.actor,
            title = excluded.title,
            goal_hash = excluded.goal_hash,
            app_name = excluded.app_name,
            bundle_identifier = excluded.bundle_identifier,
            status = excluded.status,
            failure_kind = excluded.failure_kind,
            root_audit_event_id = COALESCE(excluded.root_audit_event_id, agent_trace.root_audit_event_id),
            total_input_tokens = excluded.total_input_tokens,
            total_cache_read_tokens = excluded.total_cache_read_tokens,
            total_cache_creation_tokens = excluded.total_cache_creation_tokens,
            total_output_tokens = excluded.total_output_tokens,
            total_reasoning_tokens = excluded.total_reasoning_tokens,
            total_cost_microusd = excluded.total_cost_microusd,
            redaction_policy = excluded.redaction_policy,
            metadata_json = excluded.metadata_json;
        """
        try withStatement(sql) { statement in
            Self.traceBind(safe.traceID, at: 1, in: statement)
            Self.traceBind(Self.traceDateString(safe.startedAt), at: 2, in: statement)
            Self.traceBind(safe.endedAt.map(Self.traceDateString), at: 3, in: statement)
            Self.traceBind(safe.surface, at: 4, in: statement)
            Self.traceBind(safe.actor, at: 5, in: statement)
            Self.traceBind(safe.title, at: 6, in: statement)
            Self.traceBind(safe.goalHash, at: 7, in: statement)
            Self.traceBind(safe.appName, at: 8, in: statement)
            Self.traceBind(safe.bundleIdentifier, at: 9, in: statement)
            Self.traceBind(safe.status.rawValue, at: 10, in: statement)
            Self.traceBind(safe.failureKind, at: 11, in: statement)
            Self.traceBind(safe.rootAuditEventID, at: 12, in: statement)
            Self.traceBind(Int64(safe.totalInputTokens), at: 13, in: statement)
            Self.traceBind(Int64(safe.totalCacheReadTokens), at: 14, in: statement)
            Self.traceBind(Int64(safe.totalCacheCreationTokens), at: 15, in: statement)
            Self.traceBind(Int64(safe.totalOutputTokens), at: 16, in: statement)
            Self.traceBind(Int64(safe.totalReasoningTokens), at: 17, in: statement)
            Self.traceBind(safe.totalCostMicrousd, at: 18, in: statement)
            Self.traceBind(safe.redactionPolicy, at: 19, in: statement)
            Self.traceBind(safe.metadataJSON, at: 20, in: statement)
            try stepDone(statement)
        }
        return safe
    }

    @discardableResult
    public func upsertAgentSpan(_ row: AgentSpanRow) throws -> AgentSpanRow {
        let safe = AgentSpanRow(
            spanID: row.spanID,
            traceID: row.traceID,
            parentSpanID: row.parentSpanID,
            auditEventID: row.auditEventID,
            kind: row.kind,
            name: Self.sanitizeStoredText(row.name) ?? row.name,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            durationMs: row.durationMs,
            status: row.status,
            failureKind: Self.sanitizeStoredText(row.failureKind),
            genAIOperation: Self.sanitizeStoredText(row.genAIOperation),
            modelProvider: Self.sanitizeStoredText(row.modelProvider),
            modelName: Self.sanitizeStoredText(row.modelName),
            toolName: Self.sanitizeStoredText(row.toolName),
            toolType: Self.sanitizeStoredText(row.toolType),
            appName: Self.sanitizeStoredText(row.appName),
            recordedContextID: row.recordedContextID,
            inputEventID: row.inputEventID,
            inputTokens: row.inputTokens,
            cacheReadInputTokens: row.cacheReadInputTokens,
            cacheCreationInputTokens: row.cacheCreationInputTokens,
            outputTokens: row.outputTokens,
            reasoningOutputTokens: row.reasoningOutputTokens,
            costMicrousd: row.costMicrousd,
            promptSHA256: Self.sanitizeStoredText(row.promptSHA256),
            responseSHA256: Self.sanitizeStoredText(row.responseSHA256),
            attributesJSON: Self.sanitizeStoredText(row.attributesJSON)
        )
        let sql = """
        INSERT INTO agent_span
            (span_id, trace_id, parent_span_id, audit_event_id, kind, name, started_at, ended_at, duration_ms, status,
             failure_kind, gen_ai_operation, model_provider, model_name, tool_name, tool_type, app_name, recorded_context_id,
             input_event_id, input_tokens, cache_read_input_tokens, cache_creation_input_tokens, output_tokens,
             reasoning_output_tokens, cost_microusd, prompt_sha256, response_sha256, attributes_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(span_id) DO UPDATE SET
            trace_id = excluded.trace_id,
            parent_span_id = excluded.parent_span_id,
            audit_event_id = COALESCE(excluded.audit_event_id, agent_span.audit_event_id),
            kind = excluded.kind,
            name = excluded.name,
            started_at = excluded.started_at,
            ended_at = excluded.ended_at,
            duration_ms = excluded.duration_ms,
            status = excluded.status,
            failure_kind = excluded.failure_kind,
            gen_ai_operation = excluded.gen_ai_operation,
            model_provider = excluded.model_provider,
            model_name = excluded.model_name,
            tool_name = excluded.tool_name,
            tool_type = excluded.tool_type,
            app_name = excluded.app_name,
            recorded_context_id = excluded.recorded_context_id,
            input_event_id = excluded.input_event_id,
            input_tokens = excluded.input_tokens,
            cache_read_input_tokens = excluded.cache_read_input_tokens,
            cache_creation_input_tokens = excluded.cache_creation_input_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_output_tokens = excluded.reasoning_output_tokens,
            cost_microusd = excluded.cost_microusd,
            prompt_sha256 = excluded.prompt_sha256,
            response_sha256 = excluded.response_sha256,
            attributes_json = excluded.attributes_json;
        """
        try withStatement(sql) { statement in
            Self.traceBind(safe.spanID, at: 1, in: statement)
            Self.traceBind(safe.traceID, at: 2, in: statement)
            Self.traceBind(safe.parentSpanID, at: 3, in: statement)
            Self.traceBind(safe.auditEventID, at: 4, in: statement)
            Self.traceBind(safe.kind.rawValue, at: 5, in: statement)
            Self.traceBind(safe.name, at: 6, in: statement)
            Self.traceBind(Self.traceDateString(safe.startedAt), at: 7, in: statement)
            Self.traceBind(safe.endedAt.map(Self.traceDateString), at: 8, in: statement)
            Self.traceBind(safe.durationMs.map(Int64.init), at: 9, in: statement)
            Self.traceBind(safe.status.rawValue, at: 10, in: statement)
            Self.traceBind(safe.failureKind, at: 11, in: statement)
            Self.traceBind(safe.genAIOperation, at: 12, in: statement)
            Self.traceBind(safe.modelProvider, at: 13, in: statement)
            Self.traceBind(safe.modelName, at: 14, in: statement)
            Self.traceBind(safe.toolName, at: 15, in: statement)
            Self.traceBind(safe.toolType, at: 16, in: statement)
            Self.traceBind(safe.appName, at: 17, in: statement)
            Self.traceBind(safe.recordedContextID, at: 18, in: statement)
            Self.traceBind(safe.inputEventID, at: 19, in: statement)
            Self.traceBind(Int64(safe.inputTokens), at: 20, in: statement)
            Self.traceBind(Int64(safe.cacheReadInputTokens), at: 21, in: statement)
            Self.traceBind(Int64(safe.cacheCreationInputTokens), at: 22, in: statement)
            Self.traceBind(Int64(safe.outputTokens), at: 23, in: statement)
            Self.traceBind(Int64(safe.reasoningOutputTokens), at: 24, in: statement)
            Self.traceBind(safe.costMicrousd, at: 25, in: statement)
            Self.traceBind(safe.promptSHA256, at: 26, in: statement)
            Self.traceBind(safe.responseSHA256, at: 27, in: statement)
            Self.traceBind(safe.attributesJSON, at: 28, in: statement)
            try stepDone(statement)
        }
        return safe
    }

    @discardableResult
    public func recordTraceEvent(_ row: TraceEventRow) throws -> TraceEventRow {
        let safe = TraceEventRow(
            eventID: row.eventID,
            traceID: row.traceID,
            spanID: row.spanID,
            auditEventID: row.auditEventID,
            createdAt: row.createdAt,
            name: Self.sanitizeStoredText(row.name) ?? row.name,
            severity: Self.sanitizeStoredText(row.severity) ?? row.severity,
            failureKind: Self.sanitizeStoredText(row.failureKind),
            attributesJSON: Self.sanitizeStoredText(row.attributesJSON)
        )
        let sql = """
        INSERT OR REPLACE INTO trace_event
            (event_id, trace_id, span_id, audit_event_id, created_at, name, severity, failure_kind, attributes_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            Self.traceBind(safe.eventID, at: 1, in: statement)
            Self.traceBind(safe.traceID, at: 2, in: statement)
            Self.traceBind(safe.spanID, at: 3, in: statement)
            Self.traceBind(safe.auditEventID, at: 4, in: statement)
            Self.traceBind(Self.traceDateString(safe.createdAt), at: 5, in: statement)
            Self.traceBind(safe.name, at: 6, in: statement)
            Self.traceBind(safe.severity, at: 7, in: statement)
            Self.traceBind(safe.failureKind, at: 8, in: statement)
            Self.traceBind(safe.attributesJSON, at: 9, in: statement)
            try stepDone(statement)
        }
        return safe
    }

    @discardableResult
    public func recordModelCost(_ row: ModelCostLedgerRow) throws -> ModelCostLedgerRow {
        let safe = ModelCostLedgerRow(
            traceID: row.traceID,
            spanID: row.spanID,
            createdAt: row.createdAt,
            provider: Self.sanitizeStoredText(row.provider) ?? row.provider,
            model: Self.sanitizeStoredText(row.model) ?? row.model,
            responseID: Self.sanitizeStoredText(row.responseID),
            priceCardVersion: Self.sanitizeStoredText(row.priceCardVersion) ?? row.priceCardVersion,
            inputTokens: row.inputTokens,
            cacheReadInputTokens: row.cacheReadInputTokens,
            cacheCreationInputTokens: row.cacheCreationInputTokens,
            outputTokens: row.outputTokens,
            reasoningOutputTokens: row.reasoningOutputTokens,
            costMicrousd: row.costMicrousd,
            billable: row.billable
        )
        let sql = """
        INSERT INTO model_cost_ledger
            (trace_id, span_id, created_at, provider, model, response_id, price_card_version, input_tokens,
             cache_read_input_tokens, cache_creation_input_tokens, output_tokens, reasoning_output_tokens,
             cost_microusd, billable)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            Self.traceBind(safe.traceID, at: 1, in: statement)
            Self.traceBind(safe.spanID, at: 2, in: statement)
            Self.traceBind(Self.traceDateString(safe.createdAt), at: 3, in: statement)
            Self.traceBind(safe.provider, at: 4, in: statement)
            Self.traceBind(safe.model, at: 5, in: statement)
            Self.traceBind(safe.responseID, at: 6, in: statement)
            Self.traceBind(safe.priceCardVersion, at: 7, in: statement)
            Self.traceBind(Int64(safe.inputTokens), at: 8, in: statement)
            Self.traceBind(Int64(safe.cacheReadInputTokens), at: 9, in: statement)
            Self.traceBind(Int64(safe.cacheCreationInputTokens), at: 10, in: statement)
            Self.traceBind(Int64(safe.outputTokens), at: 11, in: statement)
            Self.traceBind(Int64(safe.reasoningOutputTokens), at: 12, in: statement)
            Self.traceBind(safe.costMicrousd, at: 13, in: statement)
            Self.traceBind(Int64(safe.billable ? 1 : 0), at: 14, in: statement)
            try stepDone(statement)
        }
        var saved = safe
        saved.id = try lastTraceInsertID()
        return saved
    }

    @discardableResult
    public func recordTraceEval(_ row: TraceEvalRow) throws -> TraceEvalRow {
        let safe = TraceEvalRow(
            traceID: row.traceID,
            spanID: row.spanID,
            createdAt: row.createdAt,
            evaluatorKind: row.evaluatorKind,
            evaluatorName: Self.sanitizeStoredText(row.evaluatorName) ?? row.evaluatorName,
            scoreValue: row.scoreValue,
            scoreLabel: Self.sanitizeStoredText(row.scoreLabel),
            explanationRedacted: Self.sanitizeStoredText(row.explanationRedacted),
            confidence: row.confidence,
            failureKind: Self.sanitizeStoredText(row.failureKind),
            sourceSpanID: row.sourceSpanID
        )
        let sql = """
        INSERT INTO trace_eval
            (trace_id, span_id, created_at, evaluator_kind, evaluator_name, score_value, score_label,
             explanation_redacted, confidence, failure_kind, source_span_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            Self.traceBind(safe.traceID, at: 1, in: statement)
            Self.traceBind(safe.spanID, at: 2, in: statement)
            Self.traceBind(Self.traceDateString(safe.createdAt), at: 3, in: statement)
            Self.traceBind(safe.evaluatorKind.rawValue, at: 4, in: statement)
            Self.traceBind(safe.evaluatorName, at: 5, in: statement)
            Self.traceBind(safe.scoreValue, at: 6, in: statement)
            Self.traceBind(safe.scoreLabel, at: 7, in: statement)
            Self.traceBind(safe.explanationRedacted, at: 8, in: statement)
            Self.traceBind(safe.confidence, at: 9, in: statement)
            Self.traceBind(safe.failureKind, at: 10, in: statement)
            Self.traceBind(safe.sourceSpanID, at: 11, in: statement)
            try stepDone(statement)
        }
        var saved = safe
        saved.id = try lastTraceInsertID()
        return saved
    }

    public func recentAgentTraces(_ query: AgentTraceQuery = AgentTraceQuery()) throws -> [AgentTraceRow] {
        let sql = """
        SELECT trace_id, started_at, ended_at, surface, actor, title, goal_hash, app_name, bundle_identifier, status,
               failure_kind, root_audit_event_id, total_input_tokens, total_cache_read_tokens,
               total_cache_creation_tokens, total_output_tokens, total_reasoning_tokens, total_cost_microusd,
               redaction_policy, metadata_json
        FROM agent_trace
        WHERE (? IS NULL OR started_at >= ?)
          AND (? IS NULL OR started_at <= ?)
          AND (? IS NULL OR status = ?)
          AND (? IS NULL OR failure_kind = ?)
        ORDER BY started_at DESC, trace_id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            let start = query.from.map(Self.traceDateString)
            let end = query.to.map(Self.traceDateString)
            Self.traceBind(start, at: 1, in: statement)
            Self.traceBind(start, at: 2, in: statement)
            Self.traceBind(end, at: 3, in: statement)
            Self.traceBind(end, at: 4, in: statement)
            Self.traceBind(query.status?.rawValue, at: 5, in: statement)
            Self.traceBind(query.status?.rawValue, at: 6, in: statement)
            Self.traceBind(query.failureKind, at: 7, in: statement)
            Self.traceBind(query.failureKind, at: 8, in: statement)
            sqlite3_bind_int(statement, 9, Int32(max(0, min(query.limit, Int(Int32.max)))))
            var rows: [AgentTraceRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentTraceRow(statement))
            }
            return rows
        }
    }

    public func agentTraceTree(traceID: String) throws -> AgentTraceTree? {
        guard let trace = try agentTrace(traceID: traceID) else { return nil }
        return AgentTraceTree(
            trace: trace,
            spans: try agentSpans(traceID: traceID),
            events: try traceEvents(traceID: traceID),
            costs: try modelCosts(traceID: traceID),
            evals: try traceEvals(traceID: traceID)
        )
    }

    public func agentTrace(traceID: String) throws -> AgentTraceRow? {
        let sql = """
        SELECT trace_id, started_at, ended_at, surface, actor, title, goal_hash, app_name, bundle_identifier, status,
               failure_kind, root_audit_event_id, total_input_tokens, total_cache_read_tokens,
               total_cache_creation_tokens, total_output_tokens, total_reasoning_tokens, total_cost_microusd,
               redaction_policy, metadata_json
        FROM agent_trace WHERE trace_id = ? LIMIT 1;
        """
        return try withStatement(sql) { statement in
            Self.traceBind(traceID, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeAgentTraceRow(statement) : nil
        }
    }

    public func agentSpans(traceID: String) throws -> [AgentSpanRow] {
        let sql = """
        SELECT span_id, trace_id, parent_span_id, audit_event_id, kind, name, started_at, ended_at, duration_ms, status,
               failure_kind, gen_ai_operation, model_provider, model_name, tool_name, tool_type, app_name,
               recorded_context_id, input_event_id, input_tokens, cache_read_input_tokens, cache_creation_input_tokens,
               output_tokens, reasoning_output_tokens, cost_microusd, prompt_sha256, response_sha256, attributes_json
        FROM agent_span
        WHERE trace_id = ?
        ORDER BY started_at ASC, span_id ASC;
        """
        return try withStatement(sql) { statement in
            Self.traceBind(traceID, at: 1, in: statement)
            var rows: [AgentSpanRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentSpanRow(statement))
            }
            return rows
        }
    }

    public func traceEvents(traceID: String) throws -> [TraceEventRow] {
        try withStatement("""
        SELECT event_id, trace_id, span_id, audit_event_id, created_at, name, severity, failure_kind, attributes_json
        FROM trace_event WHERE trace_id = ? ORDER BY created_at ASC, event_id ASC;
        """) { statement in
            Self.traceBind(traceID, at: 1, in: statement)
            var rows: [TraceEventRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(TraceEventRow(
                    eventID: Self.traceText(statement, 0) ?? "",
                    traceID: Self.traceText(statement, 1) ?? "",
                    spanID: Self.traceText(statement, 2),
                    auditEventID: Self.traceInt64(statement, 3),
                    createdAt: Self.traceDate(from: Self.traceText(statement, 4)) ?? Date(),
                    name: Self.traceText(statement, 5) ?? "",
                    severity: Self.traceText(statement, 6) ?? "info",
                    failureKind: Self.traceText(statement, 7),
                    attributesJSON: Self.traceText(statement, 8)
                ))
            }
            return rows
        }
    }

    public func modelCosts(traceID: String) throws -> [ModelCostLedgerRow] {
        try withStatement("""
        SELECT id, trace_id, span_id, created_at, provider, model, response_id, price_card_version, input_tokens,
               cache_read_input_tokens, cache_creation_input_tokens, output_tokens, reasoning_output_tokens,
               cost_microusd, billable
        FROM model_cost_ledger WHERE trace_id = ? ORDER BY created_at ASC, id ASC;
        """) { statement in
            Self.traceBind(traceID, at: 1, in: statement)
            var rows: [ModelCostLedgerRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(ModelCostLedgerRow(
                    id: sqlite3_column_int64(statement, 0),
                    traceID: Self.traceText(statement, 1) ?? "",
                    spanID: Self.traceText(statement, 2) ?? "",
                    createdAt: Self.traceDate(from: Self.traceText(statement, 3)) ?? Date(),
                    provider: Self.traceText(statement, 4) ?? "",
                    model: Self.traceText(statement, 5) ?? "",
                    responseID: Self.traceText(statement, 6),
                    priceCardVersion: Self.traceText(statement, 7) ?? "",
                    inputTokens: Int(sqlite3_column_int(statement, 8)),
                    cacheReadInputTokens: Int(sqlite3_column_int(statement, 9)),
                    cacheCreationInputTokens: Int(sqlite3_column_int(statement, 10)),
                    outputTokens: Int(sqlite3_column_int(statement, 11)),
                    reasoningOutputTokens: Int(sqlite3_column_int(statement, 12)),
                    costMicrousd: sqlite3_column_int64(statement, 13),
                    billable: sqlite3_column_int(statement, 14) != 0
                ))
            }
            return rows
        }
    }

    public func traceEvals(traceID: String) throws -> [TraceEvalRow] {
        try withStatement("""
        SELECT id, trace_id, span_id, created_at, evaluator_kind, evaluator_name, score_value, score_label,
               explanation_redacted, confidence, failure_kind, source_span_id
        FROM trace_eval WHERE trace_id = ? ORDER BY created_at ASC, id ASC;
        """) { statement in
            Self.traceBind(traceID, at: 1, in: statement)
            var rows: [TraceEvalRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(TraceEvalRow(
                    id: sqlite3_column_int64(statement, 0),
                    traceID: Self.traceText(statement, 1) ?? "",
                    spanID: Self.traceText(statement, 2),
                    createdAt: Self.traceDate(from: Self.traceText(statement, 3)) ?? Date(),
                    evaluatorKind: TraceEvalKind(rawValue: Self.traceText(statement, 4) ?? "") ?? .rule,
                    evaluatorName: Self.traceText(statement, 5) ?? "",
                    scoreValue: Self.traceDouble(statement, 6),
                    scoreLabel: Self.traceText(statement, 7),
                    explanationRedacted: Self.traceText(statement, 8),
                    confidence: Self.traceDouble(statement, 9),
                    failureKind: Self.traceText(statement, 10),
                    sourceSpanID: Self.traceText(statement, 11)
                ))
            }
            return rows
        }
    }

    private func lastTraceInsertID() throws -> Int64 {
        try withStatement("SELECT last_insert_rowid();") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
        }
    }

    private static func decodeAgentTraceRow(_ statement: OpaquePointer) -> AgentTraceRow {
        AgentTraceRow(
            traceID: traceText(statement, 0) ?? "",
            startedAt: traceDate(from: traceText(statement, 1)) ?? Date(),
            endedAt: traceDate(from: traceText(statement, 2)),
            surface: traceText(statement, 3) ?? "assist",
            actor: traceText(statement, 4) ?? "agent",
            title: traceText(statement, 5) ?? "",
            goalHash: traceText(statement, 6),
            appName: traceText(statement, 7),
            bundleIdentifier: traceText(statement, 8),
            status: AgentStoredTraceStatus(rawValue: traceText(statement, 9) ?? "") ?? .running,
            failureKind: traceText(statement, 10),
            rootAuditEventID: traceInt64(statement, 11),
            totalInputTokens: Int(sqlite3_column_int(statement, 12)),
            totalCacheReadTokens: Int(sqlite3_column_int(statement, 13)),
            totalCacheCreationTokens: Int(sqlite3_column_int(statement, 14)),
            totalOutputTokens: Int(sqlite3_column_int(statement, 15)),
            totalReasoningTokens: Int(sqlite3_column_int(statement, 16)),
            totalCostMicrousd: sqlite3_column_int64(statement, 17),
            redactionPolicy: traceText(statement, 18) ?? "content-ref-only",
            metadataJSON: traceText(statement, 19)
        )
    }

    private static func decodeAgentSpanRow(_ statement: OpaquePointer) -> AgentSpanRow {
        AgentSpanRow(
            spanID: traceText(statement, 0) ?? "",
            traceID: traceText(statement, 1) ?? "",
            parentSpanID: traceText(statement, 2),
            auditEventID: traceInt64(statement, 3),
            kind: AgentStoredSpanKind(rawValue: traceText(statement, 4) ?? "") ?? .step,
            name: traceText(statement, 5) ?? "",
            startedAt: traceDate(from: traceText(statement, 6)) ?? Date(),
            endedAt: traceDate(from: traceText(statement, 7)),
            durationMs: traceInt64(statement, 8).map(Int.init),
            status: AgentStoredTraceStatus(rawValue: traceText(statement, 9) ?? "") ?? .running,
            failureKind: traceText(statement, 10),
            genAIOperation: traceText(statement, 11),
            modelProvider: traceText(statement, 12),
            modelName: traceText(statement, 13),
            toolName: traceText(statement, 14),
            toolType: traceText(statement, 15),
            appName: traceText(statement, 16),
            recordedContextID: traceInt64(statement, 17),
            inputEventID: traceInt64(statement, 18),
            inputTokens: Int(sqlite3_column_int(statement, 19)),
            cacheReadInputTokens: Int(sqlite3_column_int(statement, 20)),
            cacheCreationInputTokens: Int(sqlite3_column_int(statement, 21)),
            outputTokens: Int(sqlite3_column_int(statement, 22)),
            reasoningOutputTokens: Int(sqlite3_column_int(statement, 23)),
            costMicrousd: sqlite3_column_int64(statement, 24),
            promptSHA256: traceText(statement, 25),
            responseSHA256: traceText(statement, 26),
            attributesJSON: traceText(statement, 27)
        )
    }

    private static func traceBind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func traceBind(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private static func traceBind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private static func traceText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func traceInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private static func traceDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private static func traceDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func traceDate(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
