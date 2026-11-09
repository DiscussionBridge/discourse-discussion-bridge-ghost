# frozen_string_literal: true

require "cgi"
require "digest"
require "nokogiri"

module DiscussionBridgeGhost
  class PostPresentation
    def self.render(source, article, owner:, resource:, native_id:)
      topic = Topic.find(source.fetch("topic_id"))
      guardian = Guardian.new
      raise Error.new("source_ineligible") unless guardian.can_see_topic?(topic)

      replies = public_replies(topic, guardian).map { |text| "<li>#{CGI.escapeHTML(text)}</li>" }
      comments = replies.empty? ? "<p>No comments yet.</p>" : "<ol>#{replies.join}</ol>"
      link = CGI.escapeHTML(source.fetch("topic_url"))
      revision = CGI.escapeHTML(source.fetch("source_revision"))
      <<~HTML.chomp
        <section data-db-owner="#{owner}" data-db-resource="#{resource}" data-db-native="#{native_id}" data-db-revision="#{revision}">
        <div data-db-article="true">#{article}</div>
        <section data-db-mode="simple"><h2>Comments</h2>#{comments}<a data-db-discussion="true" href="#{link}">Open discussion</a></section>
        </section>
      HTML
    end

    def self.public_replies(topic, guardian)
      Post.where(topic_id: topic.id, post_type: Post.types[:regular], hidden: false, deleted_at: nil)
        .where("post_number > 1").order(:post_number).limit(50)
        .filter_map do |post|
          next unless guardian.can_see_post?(post)
          Nokogiri::HTML5.fragment(post.cooked).text
        end
    end

    def self.digest(html, owner:, source_url:, ghost_url:)
      raise Error.new("public_verification_failed") unless html.is_a?(String) && html.valid_encoding?
      matches = Nokogiri::HTML5.fragment(html).css("section[data-db-owner]").select { |node| node["data-db-owner"] == owner }
      raise Error.new("public_verification_failed") unless matches.one?

      fragment = matches.first
      links = fragment.css("a[data-db-discussion]")
      raise Error.new("public_verification_failed") unless links.one?

      # Ghost may append its own referral to the discussion link during rendering.
      separator = URI.parse(source_url).query ? "&" : "?"
      referral = URI.encode_www_form_component(URI.parse(ghost_url).hostname)
      rewritten = "#{source_url}#{separator}ref=#{referral}"
      raise Error.new("public_verification_failed") unless [source_url, rewritten].include?(links.first["href"])

      links.first["href"] = source_url
      Digest::SHA256.hexdigest(fragment.to_html)
    end
  end
end
