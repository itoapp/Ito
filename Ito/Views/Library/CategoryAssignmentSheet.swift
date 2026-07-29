import SwiftUI

struct CategoryAssignmentSheet: View {
    let itemId: String

    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddSheet = false
    @State private var newCategoryName = ""
    @State private var newlyCreatedCategoryId: String?

    /// The set of category IDs this item currently belongs to.
    private var activeLinks: Set<String> {
        Set(libraryManager.links.filter { $0.itemId == itemId }.map { $0.categoryId })
    }

    /// User-created categories only — we never show the system "Uncategorized" bucket.
    private var userCategories: [LibraryCategory] {
        libraryManager.categories.filter { !$0.isSystemCategory }
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    if userCategories.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 32, weight: .thin))
                                    .foregroundStyle(.secondary)
                                Text("No custom lists yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Create a list below to organize your library.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    } else {
                        Section {
                            ForEach(userCategories) { cat in
                                categoryRow(for: cat)
                                    .id(cat.id)
                            }
                        } header: {
                            Text("Your Lists")
                        } footer: {
                            Text("Tap a list to add or remove this series. Series always remain in your library even if removed from all lists.")
                        }
                    }

                    Section {
                        Button {
                            showingAddSheet.toggle()
                        } label: {
                            Label("New List", systemImage: "plus")
                                .font(.body.weight(.medium))
                        }
                    }
                }
                .navigationTitle("Add to List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                        .font(.body.weight(.semibold))
                    }
                }
                .onChange(of: newlyCreatedCategoryId) { newId in
                    if let id = newId {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationView {
                Form {
                    Section {
                        TextField("List Name", text: $newCategoryName)
                            .font(.body)
                    } footer: {
                        Text("Enter a name for your new list.")
                    }
                }
                .navigationTitle("New List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showingAddSheet = false
                            newCategoryName = ""
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Create") {
                            let name = newCategoryName
                            Task {
                                guard !name.isEmpty else { return }
                                if let newId = try? await libraryManager.createCategory(name: name) {
                                    newlyCreatedCategoryId = newId
                                    // Auto-assign the item to the newly created list
                                    libraryManager.toggleCategory(forItemId: itemId, categoryId: newId)
                                }
                                newCategoryName = ""
                                showingAddSheet = false
                            }
                        }
                        .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(for cat: LibraryCategory) -> some View {
        let isLinked = activeLinks.contains(cat.id)

        Button {
            triggerHaptic()
            libraryManager.toggleCategory(forItemId: itemId, categoryId: cat.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.name)
                        .foregroundColor(.primary)

                    if isLinked {
                        Text("Added")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(cat.name)
                .accessibilityHint(isLinked ? "Double tap to remove from this list" : "Double tap to add to this list")

                Spacer()

                if isLinked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundColor(Color(.tertiaryLabel))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isLinked)
        }
    }

    private func triggerHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
