import OSLog
import SwiftUI
import GRDB

struct CategorySettingsView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    @State private var showingAddCategory = false
    @State private var newCategoryName = ""

    @State private var categoryToDelete: LibraryCategory?

    var body: some View {
        List {
            Section {
                // Pin the system "Uncategorized" category at the top
                if let sysCat = libraryManager.categories.first(where: { $0.isSystemCategory }) {
                    Text(sysCat.name)
                        .foregroundColor(.secondary)
                        .deleteDisabled(true)
                        .moveDisabled(true)
                }

                let userCategories = libraryManager.categories.filter { !$0.isSystemCategory }

                ForEach(userCategories) { cat in
                    NavigationLink(destination: EditCategoryView(category: cat)) {
                        Text(cat.name)
                    }
                }
                .onDelete { indexSet in
                    // Present confirmation before deleting
                    if let index = indexSet.first {
                        let cat = userCategories[index]
                        triggerWarningHaptic()
                        categoryToDelete = cat
                    }
                }
                .onMove { indices, newOffset in
                    var mutableUserCategories = userCategories
                    mutableUserCategories.move(fromOffsets: indices, toOffset: newOffset)

                    // Reorder in DB. System category stays 0.
                    let sysCategories = libraryManager.categories.filter { $0.isSystemCategory }
                    let newOrder = sysCategories + mutableUserCategories
                    libraryManager.reorderCategories(newOrder: newOrder)
                }
            } header: {
                Text("Your Lists")
            }
        }
        .navigationTitle("Manage Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddCategory.toggle()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .confirmationDialog(
            "Delete \(categoryToDelete?.name ?? "List")?",
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete List", role: .destructive) {
                if let id = categoryToDelete?.id {
                    libraryManager.deleteCategory(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in this list will be safely moved to Uncategorized.")
        }
        .sheet(isPresented: $showingAddCategory) {
            NavigationView {
                Form {
                    Section {
                        TextField("List Name", text: $newCategoryName)
                            .font(.body)
                    } footer: {
                        Text("Enter a name for your new category.")
                    }
                }
                .navigationTitle("New List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showingAddCategory = false
                            newCategoryName = ""
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Create") {
                            Task {
                                guard !newCategoryName.isEmpty else { return }
                                _ = try? await libraryManager.createCategory(name: newCategoryName)
                                newCategoryName = ""
                                showingAddCategory = false
                            }
                        }
                        .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func triggerWarningHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}

struct EditCategoryView: View {
    let category: LibraryCategory
    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("List Name", text: $name)
                    .font(.body)
            } footer: {
                Text("Rename your category. Tap outside to dismiss.")
            }
        }
        .navigationTitle("Edit List")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = category.name
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    let newName = name
                    Task {
                        // Rename logic here: fetch category and update in DB pool
                        do {
                            try await AppDatabase.shared.dbPool.write { db in
                                var updated = category
                                updated.name = newName
                                try updated.update(db)
                            }
                            dismiss()
                        } catch {
                            AppLogger.database.error("Error renaming: \(error)")
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
