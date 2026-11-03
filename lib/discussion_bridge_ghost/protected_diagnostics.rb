# frozen_string_literal: true

module DiscussionBridgeGhost
  # Never let generic diagnostics/serializers walk protected instance variables.
  # Operator/API projections must explicitly select their public fields.
  module ProtectedDiagnostics
    def inspect
      "#<#{self.class.name} [protected data omitted]>"
    end

    def to_s
      inspect
    end

    def pretty_print(printer)
      printer.text(inspect)
    end

    def as_json(*)
      { "type" => self.class.name, "protected" => true }
    end

    def to_json(*arguments)
      as_json.to_json(*arguments)
    end
  end
end
