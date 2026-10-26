if WIP < 0 or WIP /= NIn - NOut or (UseCONWIP and WIP > K)
    ValidationError := "WIP conservation or cap violation"
    EventController.stop
end
