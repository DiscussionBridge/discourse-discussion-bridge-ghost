# frozen_string_literal: true

require "cgi"
require "digest"
require "nokogiri"
require "uri"

module DiscussionBridgeGhost
  class PostPresentation
    def self.render(source, article, forum_name:, owner:, resource:, native_id:)
      topic = Topic.find(source.fetch("topic_id"))
      guardian = Guardian.new
      raise Error.new("source_ineligible") unless guardian.can_see_topic?(topic)

      link = CGI.escapeHTML(source.fetch("topic_url"))
      title = CGI.escapeHTML(source.fetch("title"))
      forum = CGI.escapeHTML(forum_name)
      revision = CGI.escapeHTML(source.fetch("source_revision"))
      first = Post.find_by(topic_id: topic.id, post_number: 1)
      author = first&.user if first && guardian.can_see_post?(first)
      origin = URI.parse(source.fetch("topic_url"))
      byline = source.fetch("source_authors").map do |entry|
        label = CGI.escapeHTML(entry.fetch("name"))
        if author&.active? && !author.staged? && author.id.to_s == entry.fetch("id") &&
            author.username.match?(/\A[a-z0-9_][a-z0-9_.-]*\z/i)
          profile = CGI.escapeHTML((origin + "/u/#{author.username}").to_s)
          %(<a data-db-source-author="true" href="#{profile}">#{label}</a>)
        else
          label
        end
      end.join(", ")
      byline = byline.empty? ? "" : "<p>Originally authored by #{byline}</p>"
      <<~HTML.chomp
        <section data-db-owner="#{owner}" data-db-resource="#{resource}" data-db-native="#{native_id}" data-db-revision="#{revision}">
        <div data-db-article="true">#{article}</div>
        <aside class="discussionbridge-publication">#{byline}<p>Originally published as <a data-db-source-title="true" href="#{link}">#{title}</a> on #{forum}.</p></aside>
        <section data-db-mode="simple"><a data-db-discussion="true" href="#{link}">Open in forum</a></section>
        </section>
      HTML
    end

    def self.current_page?(html, owner:, resource:, native_id:, revision:)
      return false unless html.is_a?(String) && html.valid_encoding?

      fragments = Nokogiri::HTML5.fragment(html).css("section[data-db-owner]").select do |fragment|
        fragment["data-db-owner"] == owner
      end
      return false unless fragments.one?

      fragment = fragments.first
      return false unless fragment["data-db-resource"] == resource &&
        fragment["data-db-native"] == native_id && fragment["data-db-revision"] == revision

      simple = fragment.element_children.select { |child| child["data-db-mode"] == "simple" }
      return false unless simple.one?

      link = simple.first.element_children.first
      simple.first.element_children.one? && link.name == "a" && link["data-db-discussion"] == "true" &&
        simple.first.children.all? { |child| child == link || (child.text? && child.text.strip.empty?) }
    end

    def self.public_replies(topic, guardian)
      Post.where(topic_id: topic.id, post_type: Post.types[:regular], hidden: false, deleted_at: nil)
        .where("post_number > 1").order(:post_number).limit(50)
        .filter_map do |post|
          next unless guardian.can_see_post?(post)
          Nokogiri::HTML5.fragment(post.cooked).text
        end
    end

    def self.digest(html, owner:, source_url:, ghost_url:, native_html: nil)
      raise Error.new("public_verification_failed") unless html.is_a?(String) && html.valid_encoding?
      matches = Nokogiri::HTML5.fragment(html).css("section[data-db-owner]").select { |node| node["data-db-owner"] == owner }
      raise Error.new("public_verification_failed") unless matches.one?

      fragment = matches.first
      restore_native_article_links!(fragment, native_html, owner, ghost_url) if native_html
      links = fragment.css("a[data-db-discussion]")
      raise Error.new("public_verification_failed") unless links.one?

      # Ghost may append its own referral to the discussion link during rendering.
      separator = URI.parse(source_url).query ? "&" : "?"
      referral = URI.encode_www_form_component(URI.parse(ghost_url).hostname)
      rewritten = "#{source_url}#{separator}ref=#{referral}"
      raise Error.new("public_verification_failed") unless [source_url, rewritten].include?(links.first["href"])

      links.first["href"] = source_url
      sources = fragment.css("a[data-db-source-title]")
      raise Error.new("public_verification_failed") if sources.size > 1
      if (source = sources.first)
        raise Error.new("public_verification_failed") unless [source_url, rewritten].include?(source["href"])

        source["href"] = source_url
      end
      forum = URI.parse(source_url)
      fragment.css("a[data-db-source-author]").each do |anchor|
        profile = URI.parse(anchor["href"].to_s)
        if [profile.scheme, profile.host, profile.port] == [forum.scheme, forum.host, forum.port] &&
            !profile.userinfo && !profile.fragment && profile.path.to_s.match?(%r{\A/u/[a-z0-9_][a-z0-9_.-]*\z}i) &&
            profile.query == "ref=#{referral}"
          profile.query = nil
          anchor["href"] = profile.to_s
        end
      rescue URI::InvalidURIError
        raise Error.new("public_verification_failed")
      end
      Digest::SHA256.hexdigest(fragment.to_html)
    end

    def self.restore_native_article_links!(public_fragment, native_html, owner, ghost_url)
      native = Nokogiri::HTML5.fragment(native_html).css("section[data-db-owner]").select { |node| node["data-db-owner"] == owner }
      raise Error.new("public_verification_failed") unless native.one?

      expected = native.first.css("[data-db-article] a")
      actual = public_fragment.css("[data-db-article] a")
      raise Error.new("public_verification_failed") unless expected.size == actual.size

      host = URI.parse(ghost_url).hostname
      referral = URI.encode_www_form_component(host)
      expected.zip(actual).each do |original, rendered|
        href = original["href"]
        next if rendered["href"] == href || !href&.match?(%r{\Ahttps?://}i)

        uri = URI.parse(href)
        next if !uri.hostname || uri.hostname == host

        base, fragment = href.split("#", 2)
        separator = uri.query.nil? ? "?" : "&"
        rewritten = "#{base}#{separator}ref=#{referral}"
        rewritten = "#{rewritten}##{fragment}" if fragment
        # Match this exact native link by position and target. The fragment
        # digest still checks every other attribute and all article content.
        rendered["href"] = href if rendered["href"] == rewritten
      rescue URI::InvalidURIError
        raise Error.new("public_verification_failed")
      end
    end
    private_class_method :restore_native_article_links!
  end
end
