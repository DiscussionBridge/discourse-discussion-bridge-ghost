# frozen_string_literal: true

module DiscussionBridgeGhost
  class AdminConnectionsController < ::Admin::AdminController
    requires_plugin "discourse-discussion-bridge-ghost"

    before_action :prevent_caching
    rescue_from DiscussionBridgeGhost::Error, with: :render_setup_error

    def index
      render json: { connections: AdminSetup.connections }
    end

    def update
      body = request.request_parameters["setup"]
      raise Error.new("ghost_setup_input_invalid") unless body.is_a?(Hash)
      options = ActionController::Parameters.new(body).permit(
        :enabled, :admin_url, :ghost_credential, :kind, :url_label, :tag,
      )
      setup = AdminSetup.find(params[:id], params[:direction])
      render json: { direction: setup.update!(options) }
    end

    private

    def prevent_caching
      response.headers["Cache-Control"] = "no-store"
    end

    def render_setup_error(error)
      fallback = I18n.t("discussion_bridge_ghost.setup_errors.save_failed", code: error.code)
      message = I18n.t("discussion_bridge_ghost.setup_errors.#{error.code}", default: fallback)
      render json: { errors: [message], code: error.code }, status: :unprocessable_entity
    end
  end
end
