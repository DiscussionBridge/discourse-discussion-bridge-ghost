export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("discussion-bridge-ghost-setup", { path: "setup" });
  },
};
