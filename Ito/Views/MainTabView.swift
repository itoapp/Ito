import SwiftUI

struct MainTabView: View {
    let appScope: AppScope

    var body: some View {
        ZStack {
            TabView {
                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }

                BrowseView()
                    .tabItem {
                        Label("Browse", systemImage: "globe")
                    }

                DiscoverView()
                    .tabItem {
                        Label("Discover", systemImage: "sparkles")
                    }

                appScope.viewFactory.makeSearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
            }

            // Present frictionless save snipes globally
            VStack {
                Spacer()
                SnackBarOverlay()
            }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        Text("MainTabView requires a prepared runtime")
    }
}
