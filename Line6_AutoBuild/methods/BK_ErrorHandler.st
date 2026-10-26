param byref errorText: string, methodPath: string, lineNumber: integer
.Models.Model.BK_RuntimeError := errorText + " | " + methodPath + " | line " + to_str(lineNumber)
errorText := ""
