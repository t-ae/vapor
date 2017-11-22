import Async
import Foundation

/// A Fluent database query builder.
public final class QueryBuilder<Model: Fluent.Model> {
    /// The query we are building
    public var query: DatabaseQuery

    /// The connection this query will be excuted on.
    /// note: don't call execute manually or fluent's
    /// hooks will not run properly.
    public let connection: Future<Model.Database.Connection>

    /// Create a new query.
    public init(
        _ model: Model.Type = Model.self,
        on connection: Future<Model.Database.Connection>
    ) {
        query = DatabaseQuery(entity: Model.entity)
        self.connection = connection
    }

    /// Begins executing the connection and sending
    /// results to the output stream.
    /// The resulting future will be completed when the
    /// query is done or fails
    public func run<T: Decodable>(
        decoding type: T.Type,
        into outputStream: @escaping BasicStream<T>.OnInput
    ) -> Future<Void> {
        return connection.then { conn -> Future<Void> in
            let promise = Promise(Void.self)
            let stream = BasicStream<T>()

            /// if the model is soft deletable, and soft deleted
            /// models were not requested, then exclude them
            if
                let type = Model.self as? (_SoftDeletable & KeyFieldMappable).Type,
                !self.query.withSoftDeleted
            {
                guard let deletedAtField = type.keyFieldMap[type._deletedAtKey] else {
                    throw "no deleted at field in key map"
                }

                try self.group(.or) { or in
                    try or.filter(deletedAtField > Date())
                    try or.filter(deletedAtField == Date.null)
                }
            }
            
            // wire up the stream
            stream.drain(onInput: outputStream)
                .catch(onError: promise.fail)
                .finally(onClose: { promise.complete() })

            // execute
            // note: this must be in this file to access connection!
            conn.execute(query: self.query, into: stream)
            return promise.future
        }
    }

    /// Convenience run that defaults to outputting a
    /// stream of the QueryBuilder's model type.
    /// Note: this also sets the model's ID if the ID
    /// type is autoincrement.
    public func run(
        into outputStream: @escaping BasicStream<Model>.OnInput
    ) -> Future<Void> {
        return connection.then { conn in
            return self.run(decoding: Model.self) { output in
                switch self.query.action {
                case .create:
                    try output.parseID(from: conn)
                default: break
                }
                try outputStream(output)
            }
        }
    }

    // Create a new query build w/ same connection.
    internal func copy() -> QueryBuilder<Model> {
        return QueryBuilder(on: connection)
    }
}

extension Model {
    internal func parseID(from conn: Database.Connection) throws {
        if fluentID == nil {
            switch ID.identifierType {
            case .autoincrementing(let convert):
                guard let lastID = conn.lastAutoincrementID else {
                    throw FluentError(
                        identifier: "noAutoincrementID",
                        reason: "No auto increment ID was returned by the database when decoding \(Self.name) models"
                    )
                }
                fluentID = convert(lastID)
            default: break
            }
        }
    }
}