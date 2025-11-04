import SwiftUI

// Screen chrome (safe areas, padding)
struct ScreenContainer<Content: View>: View {
  let title: String?
  @ViewBuilder var trailing: () -> AnyView
  @ViewBuilder var content: () -> Content
  init(title: String? = nil, @ViewBuilder trailing: @escaping () -> AnyView = { AnyView(EmptyView()) }, @ViewBuilder content: @escaping () -> Content) {
    self.title = title; self.trailing = trailing; self.content = content
  }
  var body: some View {
    VStack(spacing: 0) {
      if let t = title {
        HStack {
          Text(t).font(AppFont.h3)
          Spacer()
          trailing()
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
      }
      content()
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.lg)
    }
    .background { Rectangle().fill(AppColor.surface) }
      .ignoresSafeArea()
  }
}

// Primary CTA button style
struct PrimaryCTA: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AppFont.label)
      .foregroundColor(AppColor.text)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppColor.cta) }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

// Outline pill (dark green stroke)
struct OutlinePill: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AppFont.label)
      .foregroundColor(configuration.isPressed ? AppColor.textInv : AppColor.darkGreen)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(configuration.isPressed ? AppColor.darkGreen.opacity(0.12) : Color.clear)
      .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColor.stroke, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 18))
  }
}

// MARK: - Swoopy Reservation Buttons

struct SwoopyPrimaryButtonStyle: ButtonStyle {
  var minHeight: CGFloat = 46

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .frame(maxWidth: .infinity)
      .frame(minHeight: minHeight)
      .padding(.horizontal, 10)
      .background(Color("SwoopyGreen"))
      .foregroundStyle(Color.white)
      .clipShape(Capsule(style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
  }
}

struct SwoopyOutlineButtonStyle: ButtonStyle {
  var minHeight: CGFloat = 46

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .frame(maxWidth: .infinity)
      .frame(minHeight: minHeight)
      .padding(.horizontal, 10)
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color("SwoopyGreen"), lineWidth: 2)
      )
      .foregroundStyle(Color("SwoopyGreen"))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
  }
}

struct SwoopyPillSecondaryStyle: ButtonStyle {
  var minHeight: CGFloat = 46

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .frame(maxWidth: .infinity)
      .frame(minHeight: minHeight)
      .padding(.horizontal, 10)
      .background(Color("SwoopyLime"))
      .clipShape(Capsule(style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
  }
}

// Segmented pill group (for mode & condition)
struct SegmentedPills<Data: RandomAccessCollection, ID: Hashable, Label: View>: View {
  @Binding var selection: ID
  let items: Data
  let id: KeyPath<Data.Element, ID>
  let label: (Data.Element) -> Label
  var body: some View {
    HStack(spacing: 8) {
      ForEach(items, id: id) { item in
        let isSel = selection == item[keyPath: id]
        Button {
          selection = item[keyPath: id]
        } label: {
          label(item)
            .font(AppFont.label)
            .foregroundColor(isSel ? AppColor.textInv : AppColor.darkGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background { RoundedRectangle(cornerRadius: 18).fill(isSel ? AppColor.darkGreen : AppColor.surface) }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColor.stroke, lineWidth: 1))
        }
      }
    }
  }
}

// Circular toggle for "Provide Description"
struct CircleToggle: View {
  @Binding var isOn: Bool
  var label: String
  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { isOn.toggle() }
    } label: {
      HStack(spacing: 12) {
        ZStack {
          Circle().stroke(AppColor.stroke, lineWidth: 2).frame(width: 26, height: 26)
          if isOn { Circle().fill(AppColor.darkGreen).frame(width: 18, height: 18) }
        }
        Text(label).font(AppFont.h3).foregroundColor(AppColor.text)
        Spacer()
      }
      .contentShape(Rectangle())
    }
  }
}

// TextField capsule used in description
struct CapsuleField: View {
  @Binding var text: String
  var placeholder: String
  var body: some View {
    TextField(placeholder, text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
      .font(AppFont.body)
      .foregroundColor(AppColor.text)
      .frame(minHeight: 110, alignment: .topLeading)
      .background { RoundedRectangle(cornerRadius: 16).fill(AppColor.surface) }
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColor.stroke, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

#Preview {
  VStack(spacing: 16) {
    CircleToggle(isOn: .constant(true), label: "Provide Description")
    CapsuleField(text: .constant("Sample notes about the find."), placeholder: "Add details")
  }
  .padding()
  .background(AppColor.surface)
}
