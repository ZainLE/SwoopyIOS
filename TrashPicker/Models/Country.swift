import Foundation

struct Country: Identifiable, Equatable {
    let id: String           // ISO 3166-1 alpha-2
    let name: String
    let callingCode: String  // Digits only, no +
    
    var flag: String {
        var scalarView = String.UnicodeScalarView()
        for scalar in id.uppercased().unicodeScalars {
            if let regional = UnicodeScalar(127397 + scalar.value) {
                scalarView.append(regional)
            }
        }
        return String(scalarView)
    }
    
    var dialPrefix: String {
        "+\(callingCode)"
    }
    
    static let spain = Country(id: "ES", name: "Spain", callingCode: "34")
    
    static var all: [Country] = {
        let countries: [Country] = [
            .spain,
            Country(id: "AL", name: "Albania", callingCode: "355"),
            Country(id: "AE", name: "United Arab Emirates", callingCode: "971"),
            Country(id: "AR", name: "Argentina", callingCode: "54"),
            Country(id: "AU", name: "Australia", callingCode: "61"),
            Country(id: "AT", name: "Austria", callingCode: "43"),
            Country(id: "BH", name: "Bahrain", callingCode: "973"),
            Country(id: "BD", name: "Bangladesh", callingCode: "880"),
            Country(id: "BE", name: "Belgium", callingCode: "32"),
            Country(id: "BA", name: "Bosnia & Herzegovina", callingCode: "387"),
            Country(id: "BR", name: "Brazil", callingCode: "55"),
            Country(id: "BG", name: "Bulgaria", callingCode: "359"),
            Country(id: "CA", name: "Canada", callingCode: "1"),
            Country(id: "CL", name: "Chile", callingCode: "56"),
            Country(id: "CN", name: "China", callingCode: "86"),
            Country(id: "CO", name: "Colombia", callingCode: "57"),
            Country(id: "CR", name: "Costa Rica", callingCode: "506"),
            Country(id: "HR", name: "Croatia", callingCode: "385"),
            Country(id: "CY", name: "Cyprus", callingCode: "357"),
            Country(id: "CZ", name: "Czechia", callingCode: "420"),
            Country(id: "DK", name: "Denmark", callingCode: "45"),
            Country(id: "DO", name: "Dominican Republic", callingCode: "1"),
            Country(id: "EC", name: "Ecuador", callingCode: "593"),
            Country(id: "EG", name: "Egypt", callingCode: "20"),
            Country(id: "SV", name: "El Salvador", callingCode: "503"),
            Country(id: "EE", name: "Estonia", callingCode: "372"),
            Country(id: "FI", name: "Finland", callingCode: "358"),
            Country(id: "FR", name: "France", callingCode: "33"),
            Country(id: "DE", name: "Germany", callingCode: "49"),
            Country(id: "GR", name: "Greece", callingCode: "30"),
            Country(id: "GT", name: "Guatemala", callingCode: "502"),
            Country(id: "HN", name: "Honduras", callingCode: "504"),
            Country(id: "HK", name: "Hong Kong", callingCode: "852"),
            Country(id: "HU", name: "Hungary", callingCode: "36"),
            Country(id: "IS", name: "Iceland", callingCode: "354"),
            Country(id: "IN", name: "India", callingCode: "91"),
            Country(id: "ID", name: "Indonesia", callingCode: "62"),
            Country(id: "IE", name: "Ireland", callingCode: "353"),
            Country(id: "IL", name: "Israel", callingCode: "972"),
            Country(id: "IT", name: "Italy", callingCode: "39"),
            Country(id: "JP", name: "Japan", callingCode: "81"),
            Country(id: "JO", name: "Jordan", callingCode: "962"),
            Country(id: "KE", name: "Kenya", callingCode: "254"),
            Country(id: "KW", name: "Kuwait", callingCode: "965"),
            Country(id: "LV", name: "Latvia", callingCode: "371"),
            Country(id: "LT", name: "Lithuania", callingCode: "370"),
            Country(id: "LU", name: "Luxembourg", callingCode: "352"),
            Country(id: "MY", name: "Malaysia", callingCode: "60"),
            Country(id: "MT", name: "Malta", callingCode: "356"),
            Country(id: "MX", name: "Mexico", callingCode: "52"),
            Country(id: "MA", name: "Morocco", callingCode: "212"),
            Country(id: "NL", name: "Netherlands", callingCode: "31"),
            Country(id: "NZ", name: "New Zealand", callingCode: "64"),
            Country(id: "NI", name: "Nicaragua", callingCode: "505"),
            Country(id: "NG", name: "Nigeria", callingCode: "234"),
            Country(id: "NO", name: "Norway", callingCode: "47"),
            Country(id: "PK", name: "Pakistan", callingCode: "92"),
            Country(id: "PA", name: "Panama", callingCode: "507"),
            Country(id: "PY", name: "Paraguay", callingCode: "595"),
            Country(id: "PE", name: "Peru", callingCode: "51"),
            Country(id: "PH", name: "Philippines", callingCode: "63"),
            Country(id: "PL", name: "Poland", callingCode: "48"),
            Country(id: "PT", name: "Portugal", callingCode: "351"),
            Country(id: "PR", name: "Puerto Rico", callingCode: "1"),
            Country(id: "QA", name: "Qatar", callingCode: "974"),
            Country(id: "RO", name: "Romania", callingCode: "40"),
            Country(id: "RU", name: "Russia", callingCode: "7"),
            Country(id: "SA", name: "Saudi Arabia", callingCode: "966"),
            Country(id: "RS", name: "Serbia", callingCode: "381"),
            Country(id: "SG", name: "Singapore", callingCode: "65"),
            Country(id: "SK", name: "Slovakia", callingCode: "421"),
            Country(id: "SI", name: "Slovenia", callingCode: "386"),
            Country(id: "ZA", name: "South Africa", callingCode: "27"),
            Country(id: "KR", name: "South Korea", callingCode: "82"),
            Country(id: "SE", name: "Sweden", callingCode: "46"),
            Country(id: "CH", name: "Switzerland", callingCode: "41"),
            Country(id: "TW", name: "Taiwan", callingCode: "886"),
            Country(id: "TH", name: "Thailand", callingCode: "66"),
            Country(id: "TN", name: "Tunisia", callingCode: "216"),
            Country(id: "TR", name: "Turkey", callingCode: "90"),
            Country(id: "UA", name: "Ukraine", callingCode: "380"),
            Country(id: "GB", name: "United Kingdom", callingCode: "44"),
            Country(id: "US", name: "United States", callingCode: "1"),
            Country(id: "UY", name: "Uruguay", callingCode: "598"),
            Country(id: "VE", name: "Venezuela", callingCode: "58"),
            Country(id: "VN", name: "Vietnam", callingCode: "84")
        ]
        
        return countries.sorted { $0.name < $1.name }
    }()
    
    static func matchingPhone(_ phone: String) -> Country? {
        let digits = phone.filter(\.isNumber)
        // Try to match the longest calling code first
        let sorted = all.sorted { $0.callingCode.count > $1.callingCode.count }
        return sorted.first { digits.hasPrefix($0.callingCode) }
    }
}
