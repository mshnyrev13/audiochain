import SwiftUI
import Combine

// Subscribe only to inputs used by the library. Graph edits and selection
// must not decode favorites or filter the catalogue again.
@MainActor final class PluginLibraryState: ObservableObject {
    @Published private(set) var plugins: [PluginChoice] = []
    @Published private(set) var refreshing = false
    @Published private(set) var canAdd = true
    private var subscriptions = Set<AnyCancellable>()
    init(model: AudioModel) {
        model.$plugins.removeDuplicates().sink { [weak self] in self?.plugins = $0 }.store(in:&subscriptions)
        model.$refreshingPlugins.removeDuplicates().sink { [weak self] in self?.refreshing = $0 }.store(in:&subscriptions)
        model.$running.combineLatest(model.$busy).map { !$0 && !$1 }.removeDuplicates()
            .sink { [weak self] in self?.canAdd = $0 }.store(in:&subscriptions)
    }
}

enum PluginLibraryFilter {
    static func visible(_ plugins:[PluginChoice], favorites:Set<String>, search:String, category:PluginCategory, favoritesOnly:Bool) -> [PluginChoice] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        var starred:[PluginChoice]=[], other:[PluginChoice]=[]
        for plugin in plugins where category.contains(plugin) {
            let favorite=favorites.contains(plugin.id)
            guard (!favoritesOnly || favorite) && (query.isEmpty || plugin.name.localizedCaseInsensitiveContains(query) || plugin.manufacturer.localizedCaseInsensitiveContains(query)) else {continue}
            if favorite {starred.append(plugin)} else {other.append(plugin)}
        }
        return starred+other
    }
    static func emptyMessage(_ plugins:[PluginChoice], favorites:Set<String>, favoritesOnly:Bool) -> String {
        if favoritesOnly && !plugins.contains(where:{favorites.contains($0.id)}) {
            return "Нажмите звёздочку рядом с AU, чтобы добавить его в избранное."
        }
        return "Ничего не найдено. Попробуйте другое название или категорию."
    }
}

struct PluginLibraryView: View, Equatable {
    // The state object owns all changing library inputs. Parent graph redraws
    // may reuse this view; its own search/favorites/state updates still render.
    static func == (lhs:Self,rhs:Self) -> Bool {lhs.model === rhs.model}
    let model: AudioModel
    @StateObject private var library: PluginLibraryState
    init(model:AudioModel) {
        self.model=model
        _library=StateObject(wrappedValue:PluginLibraryState(model:model))
    }
    @AppStorage("AudioChain.ui.favoriteAUIds") private var favoriteData = "[]"
    @State private var search = ""
    @State private var category = PluginCategory.all
    @State private var favoritesOnly = false
    private var favorites: Set<String> {
        Set((try? JSONDecoder().decode([String].self,from:Data(favoriteData.utf8))) ?? [])
    }
    private func toggleFavorite(_ id: String) {
        var ids = favorites
        if ids.contains(id) {ids.remove(id)} else {ids.insert(id)}
        if let data = try? JSONEncoder().encode(ids.sorted()), let text = String(data:data,encoding:.utf8) {favoriteData = text}
    }
    var body: some View {
#if AUDIOCHAIN_DIAGNOSTICS
        let _ = UIAuditCounters.library(plugins:library.plugins.count,canAdd:library.canAdd,refreshing:library.refreshing)
#endif
        let ids = favorites
        let visible = PluginLibraryFilter.visible(library.plugins,favorites:ids,search:search,category:category,favoritesOnly:favoritesOnly)
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Text("Библиотека AU").font(.system(size:11,weight:.semibold))
                Spacer(minLength:0)
                Button {favoritesOnly.toggle()} label: {Image(systemName:favoritesOnly ? "star.fill" : "star")}
                    .foregroundStyle(favoritesOnly ? AudioTheme.accent : .secondary)
                    .help(favoritesOnly ? "Показать все AU" : "Только избранные AU")
                    .accessibilityLabel("Только избранные AU").accessibilityValue(favoritesOnly ? "Да" : "Нет")
                Button {Task {await model.rescanPlugins()}} label: {Image(systemName:"arrow.clockwise")}
                    .help("Обновить AU и папки Components").accessibilityLabel("Обновить список AU").disabled(library.refreshing)
            }.buttonStyle(.plain).font(.system(size:11))
            HStack(spacing:6) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Название или автор",text:$search).textFieldStyle(.plain).font(.system(size:10))
                    .accessibilityLabel("Поиск AU")
                if !search.isEmpty {
                    Button {search = ""} label: {Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }.font(.system(size:10)).padding(7).background(Color.black.opacity(0.18),in:RoundedRectangle(cornerRadius:6))
                .overlay(RoundedRectangle(cornerRadius:6).stroke(AudioTheme.border))
            HStack {
                Menu {
                    ForEach(PluginCategory.allCases) {choice in Button(choice.rawValue) {category = choice}}
                } label: {
                    HStack(spacing:4) {Text(category.rawValue);Image(systemName:"chevron.down").font(.system(size:7))}
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer(minLength:0)
                Text("\(visible.count)").monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size:10))
            if library.refreshing {
                HStack {ProgressView().controlSize(.mini);Text("Обновление…");Spacer();Button("Отмена") {model.cancelPluginRescan()}}
                    .font(.system(size:10)).buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:2) {
                    ForEach(visible) {plugin in
                        PluginLibraryRow(plugin:plugin,favorite:ids.contains(plugin.id),canAdd:library.canAdd,
                            add:{Task {await model.add(plugin)}},toggleFavorite:{toggleFavorite(plugin.id)})
                    }
                    if visible.isEmpty {
                        Text(PluginLibraryFilter.emptyMessage(library.plugins,favorites:ids,favoritesOnly:favoritesOnly))
                            .font(.system(size:10)).foregroundStyle(.secondary).padding(.vertical,12)
                        if !search.isEmpty || category != .all || favoritesOnly {
                            Button("Сбросить фильтры") {search="";category = .all;favoritesOnly=false}
                                .font(.system(size:10)).buttonStyle(CompactButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(10).frame(width:182).background(AudioTheme.surface)
    }
}

private struct PluginLibraryRow: View {
    let plugin: PluginChoice
    let favorite: Bool
    let canAdd: Bool
    let add: () -> Void
    let toggleFavorite: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing:4) {
            Button(action:add) {
                HStack(spacing:6) {
                    Image(systemName:plugin.unavailable == nil ? "plus" : "info.circle")
                        .font(.system(size:9)).foregroundStyle(.secondary).frame(width:10)
                    VStack(alignment:.leading,spacing:3) {
                        Text(plugin.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.tail)
                        Text(plugin.unavailable == nil ? plugin.typeLabel : "Недоступен")
                            .font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(LibraryAddButtonStyle()).disabled(!canAdd || plugin.unavailable != nil)
                .opacity(plugin.unavailable == nil && canAdd ? 1 : 0.7)
                .accessibilityLabel("Добавить \(plugin.name)")
            Button(action:toggleFavorite) {
                Image(systemName:favorite ? "star.fill" : "star")
                    .font(.system(size:9)).foregroundStyle(favorite ? AudioTheme.accent : Color.secondary.opacity(hovered ? 1 : 0.55))
                    .frame(width:18,height:28).contentShape(Rectangle())
            }.buttonStyle(.plain).help(favorite ? "Убрать из избранного" : "В избранное")
                .accessibilityLabel((favorite ? "Убрать из избранного: " : "В избранное: ")+plugin.name)
        }
        .padding(.horizontal,5).padding(.vertical,6)
        .background(hovered ? Color.white.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:6))
        .help("\(plugin.name) · \(plugin.manufacturer)\(plugin.unavailable.map {"\n"+$0} ?? "")")
        .onHover {hovered = $0}
    }
}

private struct LibraryAddButtonStyle: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
