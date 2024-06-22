import Combine


class Weather {
    @Published var temperature: Double
    init(temperature: Double) {
        self.temperature = temperature
    }
}


let weather = Weather(temperature: 20)
let weather2 = Weather(temperature: 30)
let cancellable = Publishers.CombineLatest(weather.$temperature, weather2.$temperature)
    .sink() {
        print ("Temperature now: \($0) \($1)")
}
weather.temperature = 25
weather2.temperature = 35

