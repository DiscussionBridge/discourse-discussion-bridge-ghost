# frozen_string_literal: true

require "cgi"
require_relative "native_article"

module DiscussionBridgeGhost
  # Assemble a complete owned card from an already-preserved Source. This is
  # preparation, not current receiver authority, native ownership or dispatch
  # proof. The coordinator must still qualify the native baseline and journal
  # the exact request before a write. Browser assets are installed separately;
  # an article does not invent a loader URL or fetch an unqualified script.
  class NativePublication
    include ProtectedDiagnostics

    attr_reader :html, :title, :publication_date, :source, :representation

    def initialize(
      protocol:,
      article:,
      fragment:,
      mapping:,
      work:,
      forum_name:,
      command_id:
    )
      unless protocol.is_a?(WireProtocol) && article.is_a?(NativeArticle) &&
               fragment.is_a?(OwnedFragment)
        raise Error.new("identity_conflict")
      end
      @protocol, @article, @fragment = protocol, article, fragment
      # Validate detached snapshots, never caller-owned mutable configuration.
      mapping = snapshot("Mapping", mapping)
      work = snapshot("Work", work)
      @protocol.validate!("Label", forum_name)
      @protocol.validate!("UUID", command_id)
      @source = article.source
      native_binding_matches =
        mapping.fetch("destination_native_id").nil? ||
          fragment.native_id == mapping.fetch("destination_native_id")
      unless work.fetch("action") == "publish_revision" &&
               work.fetch("state") == "leased" &&
               work.fetch("lease_generation").positive? &&
               work.fetch("mapping_id") == mapping.fetch("mapping_id") &&
               mapping.fetch("mapping_state") != "withdrawn" &&
               work.fetch("source_id") == mapping.fetch("source_id") &&
               @source.fetch("source_id") == mapping.fetch("source_id") &&
               work.fetch("source_revision") ==
                 @source.fetch("source_revision") &&
               mapping.fetch("desired_source_revision") ==
                 @source.fetch("source_revision") &&
               fragment.resource_id == mapping.fetch("resource_id") &&
               native_binding_matches
        raise Error.new("identity_conflict")
      end
      @title = @source.fetch("title")
      @publication_date = article.publication_date
      @representation = {
        "kind" => "full",
        "source_content_sha256" => @source.fetch("content_sha256")
      }.freeze
      @protocol.validate!("FullRepresentation", @representation)
      attributes =
        fragment.attributes.merge(
          "data-discussionbridge-source-revision" =>
            @source.fetch("source_revision"),
          "data-discussionbridge-mode" => mapping.fetch("presentation_mode")
        )
      attrs =
        attributes.map { |key, value| "#{key}=\"#{escape(value)}\"" }.join(" ")
      authors =
        @source
          .fetch("source_authors")
          .map { |author| escape(author.fetch("name")) }
          .join(", ")
      attribution =
        +"<hr><aside class=\"discussionbridge-publication\"><p>Published from <a data-discussionbridge-source-link href=\"#{escape(@source.fetch("topic_url"))}\">#{escape(forum_name)}</a></p>"
      attribution << "<p>Source authors: #{authors}</p>"
      attribution << "<p>Revision #{escape(@source.fetch("source_revision"))} · Ghost · DiscussionBridge for Ghost #{escape(VERSION)}</p>"
      %w[created updated].each do |activity|
        instant = @source.fetch("source_#{activity}_at")
        if instant
          attribution << "<p>Source #{activity}: <time datetime=\"#{escape(instant)}\">#{escape(instant)}</time></p>"
        end
      end
      attribution << "</aside>"
      section =
        "<section #{attrs}>#{article.html}#{attribution}<div data-discussionbridge-comments=\"#{escape(mapping.fetch("presentation_mode"))}\"></div></section>"
      @html =
        fragment.stamp_command(fragment.wrap(section), command_id: command_id)
      freeze
    rescue Error
      raise
    rescue JSON::GeneratorError, KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def escape(value)
      CGI.escapeHTML(value)
    end

    def snapshot(type, value)
      copied =
        WireJson.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      @protocol.validate!(type, copied)
      copied
    end
  end
end
