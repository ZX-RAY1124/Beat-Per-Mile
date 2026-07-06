export class Ellipse_animation {
  x: number = 0;y: number = 0;
  a: number = 0;b: number = 0;
  play: boolean = false;

  constructor(a:number, b:number) {
    this.a = a; this.b = b;
    this.x = 0; this.y = 0;
  }

  onPlay(): void{
    this.play = true;
    let back:boolean = false;
     setInterval(()=>{
      if(this.x < this.a) {
        this.y = Math.sqrt((1 - (Math.pow(this.x, 2) / Math.pow(this.a, 2))) * Math.pow(this.b, 2))
        this.x += 0.01
      } else {
        this.x = - this.a;
      }
    },0.001)

  }

  onPause(): void{
    this.play = false;
  }

}