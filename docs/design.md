#1 : initial voice

 - switch from daily check-in every single instance to just be silent and wait for user input first
 - might be related to the agent itself, not on our end but on elevenlabs


This is how I want the architecture:
on startup - retrieve the current date
then there is a variable checkedIn which is true or false
if it is false, then initiate the daily check-in




#2 : Handling daily check-ins 

 - instead instantitate a pop-up of the daily check-in at startup if the check in is not toggled: create a True/False variable for this 
 - 
