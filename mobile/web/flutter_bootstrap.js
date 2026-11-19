{{flutter_js}}
{{flutter_build_config}}

// Run the app inside #app (a phone-sized column, see index.html).
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      hostElement: document.querySelector('#app'),
    });
    await appRunner.runApp();
  },
});
